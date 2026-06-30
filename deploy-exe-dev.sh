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

append_env_if_missing() {
  local key=$1
  local value=$2

  if sudo grep -Eq "^${key}=" "${ENV_FILE}"; then
    log "preserve existing ${key} in ${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "$(quote_env "${value}")" | sudo tee -a "${ENV_FILE}" >/dev/null
    log "added ${key} to ${ENV_FILE}"
  fi
}

quote_shell() {
  printf '%q' "$1"
}

check_generated_dir_permissions() {
  local dir=$1
  local owner
  local group
  local uid
  local bad_path

  [[ -d "${dir}" ]] || return 0

  owner=$(id -un)
  group=$(id -gn)
  uid=$(id -u)
  bad_path=$(find "${dir}" \( \
    \( -type d \( ! -user "${uid}" -o ! -writable \) \) -o \
    \( -type f ! -user "${uid}" \) -o \
    \( -type l ! -user "${uid}" \) \
    \) -print -quit)

  if [[ -n "${bad_path}" ]]; then
    printf 'Generated dir failed permission check: %s\n' "${dir}" >&2
    printf 'Offending path: %s\n' "${bad_path}" >&2
    printf 'Current owner/mode:\n' >&2
    ls -ld "${bad_path}" >&2 || true
    printf 'Fix ownership/mode, then rerun: sudo chown -R %s:%s %s && sudo chmod -R u+rwX %s\n' "${owner}" "${group}" "$(quote_shell "${dir}")" "$(quote_shell "${dir}")" >&2
    exit 1
  fi
}

check_generated_dirs_writable() {
  check_generated_dir_permissions "${APP_DIR}/_build"
  check_generated_dir_permissions "${APP_DIR}/deps"
  check_generated_dir_permissions "${APP_DIR}/priv/static"
}

load_env_file() {
  set -a
  # shellcheck disable=SC1090
  source <(sudo cat "${ENV_FILE}")
  set +a
}

SERVICE_NAME=${SERVICE_NAME:-unfinal}
APP_DIR=${APP_DIR:-$(pwd -P)}
PORT=${PORT:-8000}
UNFINAL_DATA_DIR=${UNFINAL_DATA_DIR:-${APP_DIR}/../.unfinal}
DEPLOY_USER=${DEPLOY_USER:-$(id -un)}
ENV_DIR=${ENV_DIR:-/etc/${SERVICE_NAME}}
ENV_FILE=${ENV_FILE:-${ENV_DIR}/${SERVICE_NAME}.env}
SERVICE_FILE=${SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}

export PATH="/opt/elixir-1.16.3/bin:/usr/local/bin:${PATH}"
export MIX_ENV=prod
export PHX_SERVER=true
export PORT
export UNFINAL_DATA_DIR

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

if ! sudo test -f "${ENV_FILE}"; then
  tmp_env=$(mktemp)
  : >"${tmp_env}"
  sudo install -m 0640 -o root -g root "${tmp_env}" "${ENV_FILE}"
  rm -f "${tmp_env}"
  log "created ${ENV_FILE}"
fi

append_env_if_missing "MIX_ENV" "prod"
append_env_if_missing "PHX_SERVER" "true"
append_env_if_missing "PORT" "${PORT}"
append_env_if_missing "UNFINAL_DATA_DIR" "${UNFINAL_DATA_DIR}"
append_env_if_missing "UNFINAL_DATABASE_PATH" "${UNFINAL_DATA_DIR}/unfinal.sqlite3"

if ! sudo grep -Eq '^SECRET_KEY_BASE=' "${ENV_FILE}"; then
  if command -v openssl >/dev/null 2>&1; then
    generated_secret=$(openssl rand -base64 64 | tr -d '\n')
  else
    generated_secret=$(mix phx.gen.secret)
  fi

  append_env_if_missing "SECRET_KEY_BASE" "${generated_secret}"
else
  log "preserve existing SECRET_KEY_BASE in ${ENV_FILE}"
fi

load_env_file

sqlite_dir=$(dirname "${UNFINAL_DATABASE_PATH}")
log "ensure SQLite dir ${sqlite_dir}"
sudo install -d -m 0750 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${sqlite_dir}"

check_generated_dirs_writable

log "fetch deps"
mix deps.get --only prod

log "compile"
mix compile

log "build assets"
mix assets.deploy

log "run schema migrations"
mix ecto.migrate

log "reload and restart unfinal"
log "write systemd service ${SERVICE_FILE}"
tmp_service=$(mktemp)
cat >"${tmp_service}" <<EOF_SERVICE
[Unit]
Description=Unfinal Phoenix app
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
  sleep 3
  if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    sudo systemctl --no-pager --full status "${SERVICE_NAME}.service"
    log "deploy complete: https://$(hostname).exe.xyz"
  else
    printf '\nService started but died. Status:\n' >&2
    sudo systemctl --no-pager --full status "${SERVICE_NAME}.service" >&2 || true
    printf '\nRecent logs:\n' >&2
    sudo journalctl -u "${SERVICE_NAME}.service" -n 100 --no-pager >&2 || true
    exit 1
  fi
else
  printf '\nRestart failed. Service status:\n' >&2
  sudo systemctl --no-pager --full status "${SERVICE_NAME}.service" >&2 || true
  printf '\nRecent logs:\n' >&2
  sudo journalctl -u "${SERVICE_NAME}.service" -n 100 --no-pager >&2 || true
  exit 1
fi
