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

install_tools_and_litestream() {
  local missing_tools=()
  command -v curl    >/dev/null 2>&1 || missing_tools+=("curl")
  command -v sqlite3 >/dev/null 2>&1 || missing_tools+=("sqlite3")
  dpkg --version     >/dev/null 2>&1 || missing_tools+=("dpkg")
  [[ -f /etc/ssl/certs/ca-certificates.crt ]] || missing_tools+=("ca-certificates")

  if [[ ${#missing_tools[@]} -gt 0 ]]; then
    log "install missing tools: ${missing_tools[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y ca-certificates curl sqlite3 dpkg
  fi

  local litestream_installed=1
  if command -v litestream >/dev/null 2>&1; then
    if litestream version 2>/dev/null | grep -qF "${LITESTREAM_VERSION}"; then
      litestream_installed=0
    fi
  fi

  if [[ "${litestream_installed}" -eq 0 ]]; then
    log "Litestream ${LITESTREAM_VERSION} already installed"
    return 0
  fi

  log "install Litestream ${LITESTREAM_VERSION}"

  local deb_arch
  deb_arch=$(dpkg --print-architecture)

  local asset_arch
  case "${deb_arch}" in
    amd64) asset_arch="x86_64" ;;
    arm64) asset_arch="arm64" ;;
    *)
      printf 'Unsupported architecture for Litestream: %s\n' "${deb_arch}" >&2
      exit 1
      ;;
  esac

  local deb_name="litestream-${LITESTREAM_VERSION}-linux-${asset_arch}.deb"
  local deb_url="https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/${deb_name}"
  local tmpdir
  tmpdir=$(mktemp -d)

  curl -fsSL -o "${tmpdir}/${deb_name}" "${deb_url}"
  sudo dpkg -i "${tmpdir}/${deb_name}"
  rm -rf "${tmpdir}"

  log "Litestream ${LITESTREAM_VERSION} installed"
}



SERVICE_NAME=${SERVICE_NAME:-unfinal}
APP_DIR=${APP_DIR:-$(pwd -P)}
PORT=${PORT:-8000}
UNFINAL_DATA_DIR=${UNFINAL_DATA_DIR:-${APP_DIR}/../.unfinal}
DEPLOY_USER=${DEPLOY_USER:-$(id -un)}
ENV_DIR=${ENV_DIR:-/etc/${SERVICE_NAME}}
ENV_FILE=${ENV_FILE:-${ENV_DIR}/${SERVICE_NAME}.env}
SERVICE_FILE=${SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}

# Phase 2 Litestream variables
UNFINAL_DATABASE_PATH=${UNFINAL_DATABASE_PATH:-${UNFINAL_DATA_DIR}/unfinal.sqlite3}
LITESTREAM_VERSION=${LITESTREAM_VERSION:-0.5.12}
LITESTREAM_CONFIG=${LITESTREAM_CONFIG:-/etc/litestream/unfinal.yml}
LITESTREAM_SERVICE_NAME=${LITESTREAM_SERVICE_NAME:-unfinal-litestream}
LITESTREAM_SERVICE_FILE=${LITESTREAM_SERVICE_FILE:-/etc/systemd/system/${LITESTREAM_SERVICE_NAME}.service}
UNFINAL_LITESTREAM_REPLICA_PATH=${UNFINAL_LITESTREAM_REPLICA_PATH:-litestream/unfinal.sqlite3}

export PATH="/opt/elixir-1.16.3/bin:/usr/local/bin:${PATH}"
export MIX_ENV=prod
export PHX_SERVER=true
export PORT
export UNFINAL_DATA_DIR
export UNFINAL_DATABASE_PATH
export UNFINAL_LITESTREAM_REPLICA_PATH
export UNFINAL_S3_ACCESS_KEY_ID
export UNFINAL_S3_SECRET_ACCESS_KEY
export UNFINAL_S3_BUCKET
export UNFINAL_S3_ENDPOINT
export UNFINAL_S3_REGION

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
append_env_if_missing "UNFINAL_DATABASE_PATH" "${UNFINAL_DATABASE_PATH}"
append_env_if_missing "UNFINAL_LITESTREAM_REPLICA_PATH" "${UNFINAL_LITESTREAM_REPLICA_PATH}"

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

log "fetch deps"
mix deps.get --only prod

log "compile"
mix compile

log "build assets"
mix assets.deploy

# ── Phase 2: persistent DB directory + deploy-time Ecto migrations ──────────

sqlite_dir=$(dirname "${UNFINAL_DATABASE_PATH}")
log "ensure SQLite dir ${sqlite_dir}"
sudo install -d -m 0750 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${sqlite_dir}"

check_generated_dirs_writable

log "run Ecto migrations"
mix ecto.create
mix ecto.migrate

if [[ ! -s "${UNFINAL_DATABASE_PATH}" ]]; then
  printf 'SQLite DB file missing or empty after migrations: %s\n' "${UNFINAL_DATABASE_PATH}" >&2
  exit 1
fi

# ── Phase 2: install Litestream + write config + start service ──────────────

install_tools_and_litestream

log "write Litestream config ${LITESTREAM_CONFIG}"
sudo install -d -m 0755 -o root -g root "$(dirname "${LITESTREAM_CONFIG}")"

tmp_litestream_config=$(mktemp)
cat >"${tmp_litestream_config}" <<'EOF_LITESTREAM_CONFIG'
dbs:
  - path: ${UNFINAL_DATABASE_PATH}
    replicas:
      - type: s3
        bucket: ${UNFINAL_S3_BUCKET}
        path: ${UNFINAL_LITESTREAM_REPLICA_PATH}
        endpoint: ${UNFINAL_S3_ENDPOINT}
        region: ${UNFINAL_S3_REGION}
        access-key-id: ${UNFINAL_S3_ACCESS_KEY_ID}
        secret-access-key: ${UNFINAL_S3_SECRET_ACCESS_KEY}
EOF_LITESTREAM_CONFIG

sudo install -m 0644 -o root -g root "${tmp_litestream_config}" "${LITESTREAM_CONFIG}"
rm -f "${tmp_litestream_config}"

log "write Litestream systemd service ${LITESTREAM_SERVICE_FILE}"

tmp_litestream_service=$(mktemp)
cat >"${tmp_litestream_service}" <<EOF_LITESTREAM_SERVICE
[Unit]
Description=Unfinal Litestream SQLite backup
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/litestream replicate -config ${LITESTREAM_CONFIG}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_LITESTREAM_SERVICE

if ! sudo test -f "${LITESTREAM_SERVICE_FILE}" || ! sudo cmp -s "${tmp_litestream_service}" "${LITESTREAM_SERVICE_FILE}"; then
  sudo install -m 0644 -o root -g root "${tmp_litestream_service}" "${LITESTREAM_SERVICE_FILE}"
  log "updated ${LITESTREAM_SERVICE_FILE}"
else
  log "Litestream systemd service unchanged"
fi
rm -f "${tmp_litestream_service}"

log "reload and start Litestream service"
sudo systemctl daemon-reload
sudo systemctl enable "${LITESTREAM_SERVICE_NAME}.service"

if sudo systemctl restart "${LITESTREAM_SERVICE_NAME}.service"; then
  sleep 3
  if systemctl is-active --quiet "${LITESTREAM_SERVICE_NAME}.service"; then
    log "Litestream service is active"
  else
    printf '\nLitestream service started but died. Status:\n' >&2
    sudo systemctl --no-pager --full status "${LITESTREAM_SERVICE_NAME}.service" >&2 || true
    printf '\nRecent logs:\n' >&2
    sudo journalctl -u "${LITESTREAM_SERVICE_NAME}.service" -n 100 --no-pager >&2 || true
    exit 1
  fi
else
  printf '\nLitestream service restart failed. Status:\n' >&2
  sudo systemctl --no-pager --full status "${LITESTREAM_SERVICE_NAME}.service" >&2 || true
  printf '\nRecent logs:\n' >&2
  sudo journalctl -u "${LITESTREAM_SERVICE_NAME}.service" -n 100 --no-pager >&2 || true
  exit 1
fi

# ── Phase 4: R2→SQLite backfill ────────────────────────────────────────────

# Stop the running app first — the backfill mix task boots the full Phoenix
# application (needed for Repo + S3 adapter), which would collide with the
# already-listening production Endpoint on port 8000.
if sudo systemctl is-active --quiet "${SERVICE_NAME}.service"; then
  log "stop ${SERVICE_NAME} for backfill (will restart at end)"
  sudo systemctl stop "${SERVICE_NAME}.service"
fi

log "ensure migration reports directory"
sudo install -d -m 0750 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${UNFINAL_DATA_DIR}/migration-reports"

log "backfill R2 into SQLite"
report_path="${UNFINAL_DATA_DIR}/migration-reports/r2-to-sqlite-$(date -u +%Y%m%dT%H%M%SZ).json"
mix unfinal.migrate_r2_to_sqlite --commit --report "${report_path}"

# ── Phoenix app: write service + reload + restart ───────────────────────────

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
