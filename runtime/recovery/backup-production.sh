#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/release-project.sh"
release_project_load "${SCRIPT_DIR}" "$(stat -c %u "${BASH_SOURCE[0]}")" || {
  echo 'The package-owned release project policy is missing or unsafe.' >&2; exit 1;
}
source "${SCRIPT_DIR}/recovery-project.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

SERVER_DIR="${MYSCOUTEE_SERVER_DIR:-${REPO_ROOT}/server}"
if [[ -n "${MYSCOUTEE_BACKUP_DIR:-}" ]]; then
  BACKUP_DIR="${MYSCOUTEE_BACKUP_DIR}"
elif [[ "${SERVER_DIR}" == "${RELEASE_PROJECT_ROOT}/server" ]]; then
  # Keep installed backups outside ${RELEASE_PROJECT_ROOT}: apt purge intentionally
  # removes that tree.
  BACKUP_DIR="/var/backups/${RELEASE_PROJECT_NAME}"
else
  BACKUP_DIR="${REPO_ROOT}/build/packaging/dist/backups"
fi
DATABASE_NAME="${MONGO_DATABASE:-myscoutee_db}"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_NAME="${RELEASE_PROJECT_NAME}-backup-${TIMESTAMP}"
WORK_DIR="$(mktemp -d)"
REQUIRE_COMPLETE="${MYSCOUTEE_BACKUP_REQUIRE_COMPLETE:-false}"
mongo_complete=false
config_complete=true
configuration_key_complete=false
minio_complete=false
missing_components=()

if [[ "${REQUIRE_COMPLETE}" != "true" && "${REQUIRE_COMPLETE}" != "false" ]]; then
  echo "MYSCOUTEE_BACKUP_REQUIRE_COMPLETE must be true or false." >&2
  exit 1
fi

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

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

ENV_FILE="${SERVER_DIR}/.env"
configuration_key_dir_value="${OPERATOR_CONFIGURATION_KEY_DIR_HOST:-$(read_env_file_value OPERATOR_CONFIGURATION_KEY_DIR_HOST "${ENV_FILE}" || true)}"
CONFIGURATION_KEY_DIR="${MYSCOUTEE_CONFIGURATION_KEY_DIR:-$(resolve_host_path "${configuration_key_dir_value:-$(default_configuration_key_dir)}")}"

mkdir -p \
  "${BACKUP_DIR}" \
  "${WORK_DIR}/mongo" \
  "${WORK_DIR}/config" \
  "${WORK_DIR}/configuration"

project_recovery_init

if docker ps --format '{{.Names}}' | grep -qx mongodb; then
  if docker exec mongodb sh -lc "mongodump --username \"\${MONGO_APP_USERNAME:-guest}\" --password \"\${MONGO_APP_PASSWORD:-guest}\" --authenticationDatabase \"\${MONGO_APP_DATABASE:-${DATABASE_NAME}}\" --db \"\${MONGO_APP_DATABASE:-${DATABASE_NAME}}\" --archive --gzip" > "${WORK_DIR}/mongo/${DATABASE_NAME}.archive.gz"; then
    mongo_complete=true
  else
    rm -f -- "${WORK_DIR}/mongo/${DATABASE_NAME}.archive.gz"
    missing_components+=("mongodb")
    echo "Warning: MongoDB dump failed." >&2
  fi
else
  missing_components+=("mongodb")
  echo "Warning: mongodb container is not running; Mongo backup skipped." >&2
fi

for config_file in .env .env.secrets docker-compose-prod.yml; do
  if [[ -f "${SERVER_DIR}/${config_file}" ]]; then
    if [[ "${config_file}" == ".env.secrets" ]]; then
      install -m 0600 "${SERVER_DIR}/${config_file}" "${WORK_DIR}/config/${config_file}"
    else
      install -m 0644 "${SERVER_DIR}/${config_file}" "${WORK_DIR}/config/${config_file}"
    fi
  else
    config_complete=false
    missing_components+=("config:${config_file}")
    echo "Warning: production configuration is missing: ${config_file}" >&2
  fi
done

configuration_key="${CONFIGURATION_KEY_DIR}/deployment-master-key"
if [[ -L "${CONFIGURATION_KEY_DIR}" || -L "${configuration_key}" ]]; then
  echo "Operator configuration master-key backup path must not be symbolic." >&2
  exit 1
elif [[ -f "${configuration_key}" \
  && "$(stat -c '%h' "${configuration_key}")" == "1" ]]; then
  configuration_key_value="$(< "${configuration_key}")"
  configuration_key_size="$(stat -c '%s' "${configuration_key}")"
  if [[ "${configuration_key_value}" =~ ^[0-9a-f]{64}$ \
    && ( "${configuration_key_size}" == "64" \
      || "${configuration_key_size}" == "65" ) ]]; then
    install -m 0640 \
      "${configuration_key}" \
      "${WORK_DIR}/configuration/deployment-master-key"
    configuration_key_complete=true
  else
    missing_components+=("operator-configuration-key")
    echo "Warning: operator configuration master key is invalid." >&2
  fi
else
  missing_components+=("operator-configuration-key")
  echo "Warning: operator configuration master key is missing or unsafe." >&2
fi

project_backup

if [[ -d "${SERVER_DIR}/data/minio" ]]; then
  if find "${SERVER_DIR}/data/minio" -type l -print -quit | grep -q .; then
    echo "MinIO backup path must not contain symbolic links." >&2
    exit 1
  elif tar -C "${SERVER_DIR}/data" -czf "${WORK_DIR}/minio-data.tar.gz" minio; then
    minio_complete=true
  else
    rm -f -- "${WORK_DIR}/minio-data.tar.gz"
    missing_components+=("minio")
    echo "Warning: MinIO data backup failed." >&2
  fi
else
  missing_components+=("minio")
  echo "Warning: MinIO data directory not found; MinIO backup skipped." >&2
fi

missing_json="$(printf '%s\n' "${missing_components[@]}" \
  | jq -Rsc 'split("\n") | map(select(length > 0))')"
complete=false
if (( ${#missing_components[@]} == 0 )); then
  complete=true
fi
jq -n \
  --arg createdAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --argjson project "$(project_backup_manifest)" \
  --argjson complete "${complete}" \
  --argjson mongo "${mongo_complete}" \
  --argjson config "${config_complete}" \
  --argjson configurationKey "${configuration_key_complete}" \
  --argjson minio "${minio_complete}" \
  --argjson missing "${missing_json}" \
  '{
    schemaVersion: 1,
    createdAt: $createdAt,
    complete: $complete,
    components: {
      mongodb: $mongo,
      configuration: $config,
      operatorConfigurationKey: $configurationKey,
      minio: $minio
    },
    missing: $missing
  } * $project' > "${WORK_DIR}/backup-manifest.json"

if [[ "${REQUIRE_COMPLETE}" == "true" && "${complete}" != "true" ]]; then
  echo "Complete backup required; missing: ${missing_components[*]}" >&2
  exit 1
fi

tar -C "${WORK_DIR}" -czf "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" .
chmod 0600 "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
sync -f "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
sync -f "${BACKUP_DIR}"

echo "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
