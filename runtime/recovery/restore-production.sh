#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ "${CONFIRM_RESTORE:-}" != "true" ]]; then
  echo "Restore is destructive. Re-run with CONFIRM_RESTORE=true." >&2
  exit 1
fi

BACKUP_ARCHIVE="${1:-}"
if [[ -z "${BACKUP_ARCHIVE}" || ! -f "${BACKUP_ARCHIVE}" ]]; then
  echo "Usage: CONFIRM_RESTORE=true $0 /path/to/myscoutee-backup.tar.gz" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/release-project.sh"
release_project_load "${SCRIPT_DIR}" "$(stat -c %u "${BASH_SOURCE[0]}")" || {
  echo 'The package-owned release project policy is missing or unsafe.' >&2; exit 1;
}
source "${SCRIPT_DIR}/recovery-project.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

SERVER_DIR="${MYSCOUTEE_SERVER_DIR:-${REPO_ROOT}/server}"
DATABASE_NAME="${MONGO_DATABASE:-myscoutee_db}"
WORK_DIR="$(mktemp -d)"
COMPOSE_WRAPPER="${SCRIPT_DIR}/myscoutee-compose.sh"
BACKEND_CONTAINER="$(jq -er '.images[] | select(.service=="profilemanagement") | .container' "$RELEASE_PROJECT_POLICY")"
BACKEND_RESTART_REQUIRED=false
RESTORE_INCOMPLETE=false
STAGED_CONFIGURATION_KEY=""

read_env_file_value() {
  local key="$1"
  local file="$2"
  local line value

  [[ -f "${file}" ]] || return 1
  line="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "${file}" | tail -n 1)"
  [[ -n "${line}" ]] || return 1

  value="${line%$'\r'}"
  if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi

  printf '%s' "${value}"
}

resolve_host_path() {
  local value="$1"

  case "${value}" in
    /*)
      printf '%s' "${value}"
      ;;
    *)
      printf '%s/%s' "${SERVER_DIR}" "${value#./}"
      ;;
  esac
}

default_configuration_key_dir() {
  if [[ "${SERVER_DIR}" == "${RELEASE_PROJECT_ROOT}/server" ]]; then
    printf '/etc/%s/configuration' "${RELEASE_PROJECT_NAME}"
  else
    printf '%s/data/configuration' "${SERVER_DIR}"
  fi
}

validate_configuration_key() {
  local key_file="$1"
  local encoded size

  if [[ ! -f "${key_file}" || -L "${key_file}" \
    || "$(stat -c '%h' "${key_file}")" != "1" ]]; then
    echo "Backup operator configuration master key is unsafe." >&2
    return 1
  fi
  encoded="$(< "${key_file}")"
  size="$(stat -c '%s' "${key_file}")"
  if [[ ! "${encoded}" =~ ^[0-9a-f]{64}$ \
    || ( "${size}" != "64" && "${size}" != "65" ) ]]; then
    echo "Backup operator configuration master key is invalid." >&2
    return 1
  fi
}

stop_restore_backend() {
  if [[ "${BACKEND_RESTART_REQUIRED}" == "true" ]]; then
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1 \
    || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$BACKEND_CONTAINER"; then
    return 0
  fi
  if [[ ! -x "${COMPOSE_WRAPPER}" ]]; then
    echo "Cannot safely stop the application backend; Compose wrapper is missing: ${COMPOSE_WRAPPER}" >&2
    return 1
  fi

  BACKEND_RESTART_REQUIRED=true
  MYSCOUTEE_SERVER_DIR="${SERVER_DIR}" \
    "${COMPOSE_WRAPPER}" stop profilemanagement
}

restart_restore_backend() {
  if [[ "${BACKEND_RESTART_REQUIRED}" != "true" ]]; then
    return 0
  fi

  MYSCOUTEE_SERVER_DIR="${SERVER_DIR}" \
    "${COMPOSE_WRAPPER}" up -d --force-recreate profilemanagement
  BACKEND_RESTART_REQUIRED=false
}

stage_configuration_key() {
  local backup_key="$1"
  local target_key

  target_key="${CONFIGURATION_KEY_DIR}/deployment-master-key"
  if [[ -L "${CONFIGURATION_KEY_DIR}" || -L "${target_key}" ]]; then
    echo "Operator configuration master-key restore target is unsafe." >&2
    return 1
  fi
  install -d -m 0750 "${CONFIGURATION_KEY_DIR}"
  STAGED_CONFIGURATION_KEY="$(
    mktemp "${CONFIGURATION_KEY_DIR}/.deployment-master-key.restore.XXXXXX"
  )"
  install -m 0640 "${backup_key}" "${STAGED_CONFIGURATION_KEY}"
  chmod 0750 "${CONFIGURATION_KEY_DIR}"
  chmod 0640 "${STAGED_CONFIGURATION_KEY}"
  if [[ "${EUID}" -eq 0 ]]; then
    chown "+0:+${MYSCOUTEE_API_GID:-$RELEASE_PROJECT_GID}" -- \
      "${CONFIGURATION_KEY_DIR}" "${STAGED_CONFIGURATION_KEY}"
  fi
  sync -f "${STAGED_CONFIGURATION_KEY}"
  sync -f "${CONFIGURATION_KEY_DIR}"
}

activate_staged_configuration_key() {
  local target_key

  [[ -n "${STAGED_CONFIGURATION_KEY}" \
    && -f "${STAGED_CONFIGURATION_KEY}" \
    && ! -L "${STAGED_CONFIGURATION_KEY}" ]] || {
    echo "Staged operator configuration master key is unavailable." >&2
    return 1
  }
  target_key="${CONFIGURATION_KEY_DIR}/deployment-master-key"
  mv -f -- "${STAGED_CONFIGURATION_KEY}" "${target_key}"
  STAGED_CONFIGURATION_KEY=""
  sync -f "${target_key}"
  sync -f "${CONFIGURATION_KEY_DIR}"
}

cleanup() {
  local exit_status=$?

  trap - EXIT
  if [[ -n "${STAGED_CONFIGURATION_KEY}" ]]; then
    rm -f -- "${STAGED_CONFIGURATION_KEY}"
  fi
  if [[ "${BACKEND_RESTART_REQUIRED}" == "true" \
    && "${RESTORE_INCOMPLETE}" == "true" ]]; then
    echo "WARNING: restore is incomplete; profilemanagement remains stopped." >&2
  elif [[ "${BACKEND_RESTART_REQUIRED}" == "true" ]]; then
    if ! restart_restore_backend; then
      echo "WARNING: unable to restart profilemanagement after restore failure." >&2
    fi
  fi
  rm -rf "${WORK_DIR}"
  exit "${exit_status}"
}
trap cleanup EXIT

ENV_FILE="${SERVER_DIR}/.env"
configuration_key_dir_value="${OPERATOR_CONFIGURATION_KEY_DIR_HOST:-$(read_env_file_value OPERATOR_CONFIGURATION_KEY_DIR_HOST "${ENV_FILE}" || true)}"
CONFIGURATION_KEY_DIR="${MYSCOUTEE_CONFIGURATION_KEY_DIR:-$(resolve_host_path "${configuration_key_dir_value:-$(default_configuration_key_dir)}")}"

project_recovery_init

tar --no-same-owner --no-same-permissions \
  -C "${WORK_DIR}" -xzf "${BACKUP_ARCHIVE}"
if find "${WORK_DIR}" -mindepth 1 \
  \( -type l -o \( ! -type f ! -type d \) -o \( -type f -links +1 \) \) \
  -print -quit | grep -q .; then
  echo "Backup archive contains links or non-regular recovery entries." >&2
  exit 1
fi

if [[ -f "${WORK_DIR}/mongo/${DATABASE_NAME}.archive.gz" \
  && ! -f "${WORK_DIR}/configuration/deployment-master-key" ]] \
  || [[ ! -f "${WORK_DIR}/mongo/${DATABASE_NAME}.archive.gz" \
    && -f "${WORK_DIR}/configuration/deployment-master-key" ]]; then
  echo "MongoDB data and its operator configuration master key must be restored together." >&2
  exit 1
fi
if [[ -e "${WORK_DIR}/configuration/deployment-master-key" \
  || -L "${WORK_DIR}/configuration/deployment-master-key" ]]; then
  validate_configuration_key \
    "${WORK_DIR}/configuration/deployment-master-key"
fi

project_restore_validate

if [[ "${RESTORE_CONFIG:-false}" == "true" && -d "${WORK_DIR}/config" ]]; then
  cp -a "${WORK_DIR}/config/." "${SERVER_DIR}/"
fi

if [[ -f "${WORK_DIR}/mongo/${DATABASE_NAME}.archive.gz" ]]; then
  if ! docker ps --format '{{.Names}}' | grep -qx mongodb; then
    echo "mongodb container is not running; start the production stack before restore." >&2
    exit 1
  fi
  stage_configuration_key \
    "${WORK_DIR}/configuration/deployment-master-key"
  stop_restore_backend
  RESTORE_INCOMPLETE=true
  docker exec -i mongodb sh -lc "mongorestore --username \"\${MONGO_APP_USERNAME:-guest}\" --password \"\${MONGO_APP_PASSWORD:-guest}\" --authenticationDatabase \"\${MONGO_APP_DATABASE:-${DATABASE_NAME}}\" --db \"\${MONGO_APP_DATABASE:-${DATABASE_NAME}}\" --drop --archive --gzip" < "${WORK_DIR}/mongo/${DATABASE_NAME}.archive.gz"
  activate_staged_configuration_key
  RESTORE_INCOMPLETE=false
fi

if [[ "${RESTORE_MINIO:-false}" == "true" && -f "${WORK_DIR}/minio-data.tar.gz" ]]; then
  (cd "${SERVER_DIR}" && docker compose -f docker-compose-prod.yml stop minio)
  rm -rf "${SERVER_DIR}/data/minio"
  mkdir -p "${SERVER_DIR}/data"
  tar -C "${SERVER_DIR}/data" -xzf "${WORK_DIR}/minio-data.tar.gz"
  (cd "${SERVER_DIR}" && docker compose -f docker-compose-prod.yml up -d minio)
fi

project_restore
restart_restore_backend

echo "Restore complete."
