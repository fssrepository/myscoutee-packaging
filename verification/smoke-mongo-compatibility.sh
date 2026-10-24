#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/release-project.sh"
release_project_load "${SCRIPT_DIR}" "$(stat -c %u "${BASH_SOURCE[0]}")" || {
  echo 'The package-owned release project policy is missing or unsafe.' >&2; exit 1;
}
source "${SCRIPT_DIR}/host-project-checks.sh"
BACKEND_CONTAINER="$(jq -er '.images[] | select(.service=="profilemanagement") | .container' "$RELEASE_PROJECT_POLICY")"

default_server_dir() {
  if [[ "${SCRIPT_DIR}" == ${RELEASE_PROJECT_ROOT}/packaging/scripts && -f ${RELEASE_PROJECT_ROOT}/server/docker-compose-prod.yml ]]; then
    printf '%s/server' "${RELEASE_PROJECT_ROOT}"
    return
  fi

  local repo_root
  repo_root="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
  printf '%s/server' "${repo_root}"
}

SERVER_DIR="${MYSCOUTEE_SERVER_DIR:-$(default_server_dir)}"
ENV_FILE="${MYSCOUTEE_ENV_FILE:-${SERVER_DIR}/.env}"
if [[ "${SERVER_DIR}" == ${RELEASE_PROJECT_ROOT}/server && -f /etc/${RELEASE_PROJECT_NAME}/${RELEASE_PROJECT_NAME}.env ]]; then
  ENV_FILE="${MYSCOUTEE_ENV_FILE:-/etc/${RELEASE_PROJECT_NAME}/${RELEASE_PROJECT_NAME}.env}"
fi

BASE_URL="${MYSCOUTEE_BASE_URL:-http://127.0.0.1}"
EXPECTED_MONGO_MINOR="${EXPECTED_MONGO_MINOR:-8.0}"
START_STACK="${START_STACK:-false}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-180}"

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

is_truthy() {
  case "${1,,}" in
    1|true|yes|on|enabled)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

compose_files() {
  local files=(-f "${SERVER_DIR}/docker-compose-prod.yml")
  local replica_set_enabled
  replica_set_enabled="$(read_env_file_value MONGO_REPLICA_SET_ENABLED "${ENV_FILE}" || true)"

  if is_truthy "${replica_set_enabled:-true}"; then
    files+=(-f "${SERVER_DIR}/docker-compose.replicaset.yml")
  fi

  printf '%s\n' "${files[@]}"
}

docker_compose() {
  local files=()
  mapfile -t files < <(compose_files)
  (cd "${SERVER_DIR}" && docker compose --env-file "${ENV_FILE}" "${files[@]}" "$@")
}

status_line() {
  printf '%-5s %s\n' "$1" "$2"
}

fail() {
  status_line fail "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

container_health() {
  docker inspect "$1" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true
}

require_existing_container_running() {
  local name="$1"
  local health
  health="$(container_health "${name}")"
  case "${health}" in
    healthy|starting|running)
      return 0
      ;;
    "")
      fail "${name} container is missing; start the stack first or set START_STACK=true"
      ;;
    *)
      fail "${name} container is ${health}; start the stack first or set START_STACK=true"
      ;;
  esac
}

wait_for_health() {
  local name="$1"
  local wanted="$2"
  local waited=0
  local health

  while (( waited <= WAIT_TIMEOUT_SECONDS )); do
    health="$(container_health "${name}")"
    if [[ "${health}" == "${wanted}" ]]; then
      status_line ok "${name} is ${wanted}"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done

  fail "${name} did not become ${wanted}; last status: ${health:-missing}"
}

mongo_eval_root() {
  local js="$1"
  docker exec -e MONGO_SMOKE_JS="${js}" mongodb sh -lc '
    mongosh --quiet \
      --username "$MONGO_INITDB_ROOT_USERNAME" \
      --password "$MONGO_INITDB_ROOT_PASSWORD" \
      --authenticationDatabase admin \
      admin \
      --eval "$MONGO_SMOKE_JS"
  '
}

mongo_eval_app() {
  local js="$1"
  docker exec -e MONGO_SMOKE_JS="${js}" mongodb sh -lc '
    mongosh --quiet \
      --username "$MONGO_APP_USERNAME" \
      --password "$MONGO_APP_PASSWORD" \
      --authenticationDatabase "${MONGO_APP_DATABASE:-production_db}" \
      "${MONGO_APP_DATABASE:-production_db}" \
      --eval "$MONGO_SMOKE_JS"
  '
}

mongo_count_root() {
  local database="$1"
  local collection="$2"
  local filter="${3:-}"
  if [[ -z "${filter}" ]]; then
    filter="{}"
  fi

  [[ "${database}" =~ ^[A-Za-z0-9_-]+$ ]] || fail "unsafe Mongo database name: ${database}"
  [[ "${collection}" =~ ^[A-Za-z0-9_-]+$ ]] || fail "unsafe Mongo collection name: ${collection}"

  mongo_eval_root "print(db.getSiblingDB('${database}').getCollection('${collection}').countDocuments(${filter}));" \
    | tail -n 1 \
    | tr -d '\r'
}

require_count() {
  local label="$1"
  local database="$2"
  local collection="$3"
  local filter="${4:-}"
  if [[ -z "${filter}" ]]; then
    filter="{}"
  fi
  local count

  count="$(mongo_count_root "${database}" "${collection}" "${filter}")"
  if ! [[ "${count}" =~ ^[0-9]+$ ]] || (( count < 1 )); then
    fail "${label} is missing from ${database}.${collection}"
  fi
  status_line ok "${label}: ${count}"
}

http_get() {
  local path="$1"
  curl -fsS "${BASE_URL%/}${path}"
}

internal_get() {
  local path="$1"
  local internal_path="${path}"

  [[ "${internal_path}" == /* \
    && "${internal_path}" != *$'\n'* \
    && "${internal_path}" != *$'\r'* ]] \
    || fail "unsafe internal HTTP path"
  case "${internal_path}" in
    /api/*)
      # Nginx removes the public /api prefix before proxying to Spring.
      internal_path="${internal_path#/api}"
      ;;
  esac
  docker exec "$BACKEND_CONTAINER" \
    wget -qO- "http://localhost:8080${internal_path}"
}

check_http_or_internal() {
  local label="$1"
  local path="$2"
  local pattern="$3"
  local body

  body="$(http_get "${path}" 2>/dev/null || true)"
  if [[ "${body}" == *"${pattern}"* ]]; then
    status_line ok "${label}"
    return 0
  fi

  # The production HTTP listener may correctly return a non-empty redirect
  # page. This host-level smoke still verifies Spring directly; public
  # redirect and TLS behavior belongs to the external deployment verifier.
  body="$(internal_get "${path}" 2>/dev/null || true)"
  if [[ "${body}" == *"${pattern}"* ]]; then
    status_line ok "${label}"
    return 0
  fi

  fail "${label} did not match expected response"
}

check_configured_mongo_image() {
  local configured_image="$1"
  local upstream_image="${configured_image}"
  if [[ "${upstream_image}" != mongo:${EXPECTED_MONGO_MINOR}.* && "${upstream_image}" != "mongo:${EXPECTED_MONGO_MINOR}" ]]; then
    upstream_image="$(docker image inspect --format '{{index .Config.Labels "io.myscoutee.upstream-reference"}}' "${configured_image}" 2>/dev/null || true)"
  fi
  if [[ "${upstream_image}" != mongo:${EXPECTED_MONGO_MINOR}.* && "${upstream_image}" != "mongo:${EXPECTED_MONGO_MINOR}" ]]; then
    fail "configured Mongo image must use upstream mongo:${EXPECTED_MONGO_MINOR}; got ${configured_image:-unset}"
  fi
  status_line ok "configured Mongo image: ${configured_image} (upstream ${upstream_image})"
}

main() {
  require_command docker
  require_command curl

  [[ -d "${SERVER_DIR}" ]] || fail "server directory not found: ${SERVER_DIR}"
  [[ -f "${ENV_FILE}" ]] || fail "env file not found: ${ENV_FILE}"

  local configured_image
  configured_image="$(read_env_file_value MONGO_IMAGE "${ENV_FILE}" || true)"
  check_configured_mongo_image "${configured_image}"

  if is_truthy "${START_STACK}"; then
    docker_compose up -d
  else
    require_existing_container_running mongodb
    require_existing_container_running "$BACKEND_CONTAINER"
  fi

  wait_for_health mongodb healthy
  wait_for_health "$BACKEND_CONTAINER" healthy

  project_smoke_dependencies

  local version fcv
  version="$(mongo_eval_root 'print(db.version())' | tail -n 1 | tr -d '\r')"
  if [[ "${version}" != "${EXPECTED_MONGO_MINOR}".* ]]; then
    fail "running Mongo version must start with ${EXPECTED_MONGO_MINOR}; got ${version}"
  fi
  status_line ok "running Mongo version: ${version}"

  local mongo_file_limit
  mongo_file_limit="$(docker exec mongodb awk '/^Max open files/ {print $4}' /proc/1/limits)"
  if [[ "${mongo_file_limit}" != unlimited ]] \
    && { [[ ! "${mongo_file_limit}" =~ ^[0-9]+$ ]] || (( mongo_file_limit < 64000 )); }; then
    fail "Mongo open-file limit must be at least 64000; got ${mongo_file_limit:-unknown}"
  fi
  status_line ok "Mongo open-file limit: ${mongo_file_limit}"

  fcv="$(mongo_eval_root 'const fcv = db.adminCommand({ getParameter: 1, featureCompatibilityVersion: 1 }).featureCompatibilityVersion; print(fcv.version || fcv);' | tail -n 1 | tr -d '\r')"
  if [[ "${fcv}" != "${EXPECTED_MONGO_MINOR}" ]]; then
    fail "Mongo featureCompatibilityVersion must be ${EXPECTED_MONGO_MINOR}; got ${fcv}"
  fi
  status_line ok "Mongo featureCompatibilityVersion: ${fcv}"

  local real_database demo_database
  real_database="$(read_env_file_value MONGO_REAL_DATABASE "${ENV_FILE}" || true)"
  real_database="${real_database:-production_db}"
  demo_database="$(read_env_file_value MONGO_DEMO_DATABASE "${ENV_FILE}" || true)"
  demo_database="${demo_database:-demo_db}"

  require_count "production i18n seed" "${real_database}" "i18n_messages"
  require_count "production privacy seed" "${real_database}" "helpCenterRevisions" '{"documentType":"privacy","active":true}'
  require_count "demo users seed" "${demo_database}" "users"
  require_count "demo privacy seed" "${demo_database}" "helpCenterRevisions" '{"documentType":"privacy","active":true}'

  project_smoke_seeds "${real_database}" "${demo_database}"

  mongo_eval_app '
    const collection = db.getCollection("_myscoutee_mongo_compat_smoke");
    collection.deleteMany({});
    collection.insertOne({ _id: "compat", nested: { score: 1 }, tags: ["mongo-8.0"], createdAt: new Date() });
    collection.updateOne({ _id: "compat" }, { $set: { "nested.score": 2 }, $currentDate: { updatedAt: true } });
    const rows = collection.aggregate([
      { $match: { _id: "compat" } },
      { $project: { _id: 0, ok: { $eq: ["$nested.score", 2] }, tagCount: { $size: "$tags" } } }
    ]).toArray();
    collection.drop();
    if (!rows[0] || rows[0].ok !== true || rows[0].tagCount !== 1) {
      throw new Error("Mongo CRUD smoke failed");
    }
    print("ok");
  ' >/dev/null
  status_line ok "Mongo app-user CRUD smoke"

  check_http_or_internal "backend health" "/api/health" '"status":"UP"'
  project_smoke_http
  check_http_or_internal "active help content" "/api/help/active?lang=en" '"documentKind":"help"'
  check_http_or_internal "active privacy content" "/api/privacy/active?lang=en" '"documentKind":"privacy"'
  check_http_or_internal "active privacy sections" "/api/privacy/active?lang=en" '"sections":[{'

  status_line ok "Mongo ${EXPECTED_MONGO_MINOR} compatibility smoke passed"
}

if [[ "${MYSCOUTEE_SMOKE_LIBRARY_ONLY:-false}" != "true" ]]; then
  main "$@"
fi
