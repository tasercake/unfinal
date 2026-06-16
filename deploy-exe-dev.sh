#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '\n==> %s\n' "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

quote_env() {
  local value=${1-}
  printf '"%s"' "${value//\"/\\\"}"
}

SERVICE_NAME=${SERVICE_NAME:-synopticon}
APP_DIR=${APP_DIR:-$(pwd -P)}
PHX_HOST=${PHX_HOST:-$(hostname).exe.xyz}
PORT=${PORT:-8000}
DEPLOY_USER=${DEPLOY_USER:-$(id -un)}
ENV_DIR=${ENV_DIR:-/etc/${SERVICE_NAME}}
ENV_FILE=${ENV_FILE:-${ENV_DIR}/${SERVICE_NAME}.env}
SERVICE_FILE=${SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}

export PATH="/opt/elixir-1.16.3/bin:/usr/local/bin:${PATH}"
export MIX_ENV=prod
export PHX_SERVER=true
export PHX_HOST
export PORT

if [[ ! -f "${APP_DIR}/mix.exs" ]]; then
  printf 'APP_DIR must point to repo root with mix.exs: %s\n' "${APP_DIR}" >&2
  exit 1
fi

require_cmd sudo
require_cmd mix
require_cmd systemctl

cd "${APP_DIR}"

log "ensure env file ${ENV_FILE}"
sudo install -d -m 0750 -o root -g root "${ENV_DIR}"

existing_secret=""
if sudo test -f "${ENV_FILE}"; then
  existing_secret=$(sudo sed -n 's/^SECRET_KEY_BASE=//p' "${ENV_FILE}" | head -n 1)
  existing_secret=${existing_secret%\"}
  existing_secret=${existing_secret#\"}
fi

if [[ -z "${existing_secret}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    existing_secret=$(openssl rand -base64 64 | tr -d '\n')
  else
    existing_secret=$(mix phx.gen.secret)
  fi
fi

tmp_env=$(mktemp)
cat >"${tmp_env}" <<EOF_ENV
MIX_ENV="prod"
PHX_SERVER="true"
PHX_HOST=$(quote_env "${PHX_HOST}")
PORT=$(quote_env "${PORT}")
SECRET_KEY_BASE=$(quote_env "${existing_secret}")
EOF_ENV

if ! sudo test -f "${ENV_FILE}" || ! sudo cmp -s "${tmp_env}" "${ENV_FILE}"; then
  sudo install -m 0640 -o root -g root "${tmp_env}" "${ENV_FILE}"
  log "updated ${ENV_FILE}"
else
  log "env file unchanged"
fi
rm -f "${tmp_env}"

log "fetch deps"
mix deps.get --only prod

log "compile"
mix compile

log "build assets"
mix assets.deploy

log "write systemd service ${SERVICE_FILE}"
tmp_service=$(mktemp)
cat >"${tmp_service}" <<EOF_SERVICE
[Unit]
Description=Synopticon Phoenix app
After=network.target

[Service]
Type=simple
User=${DEPLOY_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
Environment=PATH=/opt/elixir-1.16.3/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/bin/bash -lc 'exec mix phx.server'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SERVICE

if ! sudo test -f "${SERVICE_FILE}" || ! sudo cmp -s "${tmp_service}" "${SERVICE_FILE}"; then
  sudo install -m 0644 -o root -g root "${tmp_service}" "${SERVICE_FILE}"
  log "updated ${SERVICE_FILE}"
else
  log "systemd service unchanged"
fi
rm -f "${tmp_service}"

log "reload and restart ${SERVICE_NAME}"
sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}.service"

if sudo systemctl restart "${SERVICE_NAME}.service"; then
  sudo systemctl --no-pager --full status "${SERVICE_NAME}.service"
  log "deploy complete: https://${PHX_HOST}"
else
  printf '\nRestart failed. Service status:\n' >&2
  sudo systemctl --no-pager --full status "${SERVICE_NAME}.service" >&2 || true
  printf '\nRecent logs:\n' >&2
  sudo journalctl -u "${SERVICE_NAME}.service" -n 100 --no-pager >&2 || true
  exit 1
fi
