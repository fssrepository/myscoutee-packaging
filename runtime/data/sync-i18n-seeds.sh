#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/release-project.sh"
release_project_load "${SCRIPT_DIR}" "$(stat -c %u "${BASH_SOURCE[0]}")" || {
  echo 'The package-owned release project policy is missing or unsafe.' >&2; exit 1;
}

default_server_dir() {
  if [[ "${SCRIPT_DIR}" == ${RELEASE_PROJECT_ROOT}/packaging/scripts \
    && -f ${RELEASE_PROJECT_ROOT}/server/docker-compose-prod.yml ]]; then
    printf '%s/server' "${RELEASE_PROJECT_ROOT}"
    return
  fi

  local repo_root
  repo_root="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
  printf '%s/server' "${repo_root}"
}

SERVER_DIR="${MYSCOUTEE_SERVER_DIR:-$(default_server_dir)}"
COMPOSE_SCRIPT="${MYSCOUTEE_COMPOSE_SCRIPT:-${SCRIPT_DIR}/myscoutee-compose.sh}"
SEED_DIR_HOST="${MYSCOUTEE_I18N_SEED_DIR_HOST:-${SERVER_DIR}/docker/conf/mongodb/myscoutee_db}"
SEED_DIR_CONTAINER="${MYSCOUTEE_I18N_SEED_DIR_CONTAINER:-/docker-entrypoint-initdb.d/myscoutee_db}"
MONGO_CONTAINER="${MYSCOUTEE_MONGO_CONTAINER:-mongodb}"
WAIT_SECONDS="${MYSCOUTEE_I18N_SYNC_WAIT_SECONDS:-180}"

fail() {
  echo "MyScoutee i18n seed sync failed: $*" >&2
  exit 1
}

if [[ ! "${WAIT_SECONDS}" =~ ^[1-9][0-9]*$ || "${WAIT_SECONDS}" -gt 600 ]]; then
  fail "MYSCOUTEE_I18N_SYNC_WAIT_SECONDS must be between 1 and 600."
fi
if [[ ! -x "${COMPOSE_SCRIPT}" || -L "${COMPOSE_SCRIPT}" ]]; then
  fail "compose helper is missing, not executable, or a symbolic link: ${COMPOSE_SCRIPT}"
fi
for seed_name in i18n_messages i18n_bundles; do
  seed_file="${SEED_DIR_HOST}/${seed_name}.json"
  if [[ ! -f "${seed_file}" || -L "${seed_file}" ]]; then
    fail "managed seed is missing or a symbolic link: ${seed_file}"
  fi
done

"${COMPOSE_SCRIPT}" up -d mongodb

mongo_status=""
for ((attempt = 1; attempt <= WAIT_SECONDS; attempt++)); do
  mongo_status="$(
    docker inspect "${MONGO_CONTAINER}" \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      2>/dev/null \
      || true
  )"
  case "${mongo_status}" in
    healthy)
      break
      ;;
    unhealthy|exited|dead)
      fail "MongoDB entered ${mongo_status} state before seed synchronization."
      ;;
  esac
  sleep 1
done
if [[ "${mongo_status}" != "healthy" ]]; then
  fail "MongoDB did not become healthy within ${WAIT_SECONDS} seconds."
fi

# Startup may prepare Mongo first; schema migration then owns the seed load.
if [[ "${1:-}" == --prepare-only ]]; then
  echo "MongoDB ready for schema migration."
  exit 0
fi

for seed_name in i18n_messages i18n_bundles; do
  "${COMPOSE_SCRIPT}" exec -T \
    -e "MONGO_IMPORT_SINGLE_FILE=${SEED_DIR_CONTAINER}/${seed_name}.json" \
    mongodb \
    /docker-entrypoint-initdb.d/mongo_import.sh
done

echo "MyScoutee production i18n bundle synchronized from packaged seeds."
