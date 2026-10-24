#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/release-project.sh"
release_project_load "${SCRIPT_DIR}" "$(stat -c %u "${BASH_SOURCE[0]}")" || {
  echo 'The package-owned release project policy is missing or unsafe.' >&2; exit 1;
}
source "${SCRIPT_DIR}/host-project-checks.sh"
BACKEND_CONTAINER="$(jq -er '.images[] | select(.service=="profilemanagement") | .container' "$RELEASE_PROJECT_POLICY")"

SERVICE_NAME="${MYSCOUTEE_SERVICE_NAME:-${RELEASE_PROJECT_NAME}.service}"
COMPOSE_PROJECT="${MYSCOUTEE_COMPOSE_PROJECT:-server}"
ENV_FILE="${MYSCOUTEE_ENV_FILE:-/etc/${RELEASE_PROJECT_NAME}/${RELEASE_PROJECT_NAME}.env}"
SMOKE_SCRIPT="${MYSCOUTEE_SMOKE_SCRIPT:-${RELEASE_PROJECT_ROOT}/packaging/scripts/smoke-mongo-compatibility.sh}"
DIAGNOSTICS_SCRIPT="${MYSCOUTEE_DIAGNOSTICS_SCRIPT:-${RELEASE_PROJECT_ROOT}/packaging/scripts/deployment-diagnostics.sh}"
BASE_URL="${MYSCOUTEE_BASE_URL:-http://127.0.0.1}"
TIMEOUT_SECONDS="${MYSCOUTEE_QUALIFY_TIMEOUT_SECONDS:-300}"
STOP_ON_FAILURE=true
EXPECTED_VERSION=""
MODE=""
stage="initialization"
handling_failure=false

usage() {
  cat <<'USAGE'
Usage:
  qualify-deployment.sh restart-and-check [options]
  qualify-deployment.sh check [options]
  qualify-deployment.sh diagnostics

Options:
  --expected-version X.Y.Z       Require the installed Debian package version.
  --timeout-seconds N            Bound readiness and smoke checks (default: 300).
  --leave-running-on-failure     Do not stop the application service after a failure.
  -h, --help                     Show this help.

This is an explicit host qualification command. Debian postinst never invokes it.
Public URL, certificate-chain, redirect, and browser-facing checks belong to the
separate verify-deployment runner executed from an external machine.
USAGE
}

log() {
  printf '[qualification] %s\n' "$*"
}

fail() {
  echo "[qualification] fail: $*" >&2
  return 1
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

read_env_file_value() {
  local key="$1"
  local file="$2"
  local line value

  [[ -f "${file}" && ! -L "${file}" ]] || return 1
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

run_diagnostics() {
  if [[ -x "${DIAGNOSTICS_SCRIPT}" && ! -L "${DIAGNOSTICS_SCRIPT}" ]]; then
    "${DIAGNOSTICS_SCRIPT}" || true
    return
  fi
  log "diagnostics helper is unavailable: ${DIAGNOSTICS_SCRIPT}"
}

on_error() {
  local rc=$?

  if [[ "${handling_failure}" == true ]]; then
    exit "${rc}"
  fi
  handling_failure=true
  trap - ERR
  set +e
  log "FAILED at ${stage} (exit ${rc})"
  run_diagnostics
  if [[ "${STOP_ON_FAILURE}" == true ]] \
      && command -v systemctl >/dev/null 2>&1; then
    log "stopping ${SERVICE_NAME} after qualification failure"
    systemctl stop "${SERVICE_NAME}" || true
  fi
  exit "${rc}"
}

check_restart_loops() {
  local restarting

  command -v docker >/dev/null 2>&1 || fail "docker is required"
  restarting="$(
    docker ps -a \
      --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
      --format '{{.Names}} {{.Status}}' \
      | awk '/Restarting/ { print }'
  )"
  if [[ -n "${restarting}" ]]; then
    printf '%s\n' "${restarting}" >&2
    fail "a MyScoutee container is restart-looping"
  fi
}

wait_for_service() {
  local deadline=$((SECONDS + TIMEOUT_SECONDS))

  while (( SECONDS <= deadline )); do
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
      check_restart_loops
      log "${SERVICE_NAME} is active"
      return 0
    fi
    sleep 2
  done
  fail "${SERVICE_NAME} did not become active within ${TIMEOUT_SECONDS} seconds"
}

container_health() {
  docker inspect "$1" \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
    2>/dev/null || true
}

wait_for_container_health() {
  local container="$1"
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  local health=""

  while (( SECONDS <= deadline )); do
    health="$(container_health "${container}")"
    if [[ "${health}" == "healthy" ]]; then
      log "${container} container is healthy"
      return 0
    fi
    sleep 2
  done
  fail "${container} container did not become healthy within ${TIMEOUT_SECONDS} seconds; last status: ${health:-missing}"
}

wait_for_deployment_containers() {
  local container service
  local configuration inventory
  local compose="${MYSCOUTEE_COMPOSE_SCRIPT:-${SCRIPT_DIR}/myscoutee-compose.sh}"
  configuration="$("$compose" config --no-env-resolution --format json)" || fail "installed Compose configuration is unavailable"
  inventory="$(jq -er '.services | to_entries | select(length>0) | .[] | [.key, (.value.container_name // "")] | @tsv' <<< "$configuration")" || fail "installed container inventory is empty"
  while IFS=$'\t' read -r service container; do
    if [[ -z "$container" ]]; then
      container="$("$compose" ps -a -q "$service")" || fail "container for $service is unavailable"
      [[ -n "$container" && "$container" != *$'\n'* ]] || fail "expected one container for $service"
    fi
    wait_for_container_health "${container}"
  done <<< "$inventory"
}

verify_installed_version() {
  local installed_version

  [[ -n "${EXPECTED_VERSION}" ]] || return 0
  installed_version="$(dpkg-query -W -f='${Version}' "$RELEASE_PROJECT_NAME" 2>/dev/null || true)"
  [[ "${installed_version//\~/-}" == "${EXPECTED_VERSION//\~/-}" ]] \
    || fail "installed version ${installed_version:-missing} does not match ${EXPECTED_VERSION}"
  log "installed package version: ${installed_version}"
}

run_application_smoke() {
  local started_at="$1"
  local elapsed remaining

  [[ -x "${SMOKE_SCRIPT}" && ! -L "${SMOKE_SCRIPT}" ]] \
    || fail "smoke helper is unavailable: ${SMOKE_SCRIPT}"
  elapsed=$((SECONDS - started_at))
  remaining=$((TIMEOUT_SECONDS - elapsed))
  (( remaining >= 1 )) \
    || fail "deployment qualification exceeded ${TIMEOUT_SECONDS} seconds"
  env \
    MYSCOUTEE_BASE_URL="${BASE_URL}" \
    START_STACK=false \
    WAIT_TIMEOUT_SECONDS="${remaining}" \
    timeout --foreground "${remaining}s" \
    bash "${SMOKE_SCRIPT}"
}

check_i18n_bundle() {
  local body

  body="$(
    docker exec "$BACKEND_CONTAINER" sh -lc \
      "wget -qO- 'http://localhost:8080/i18n/bundle?lang=hu'"
  )"
  [[ "${body}" == *'"lang":"hu"'* && "${body}" == *'"data":{'* ]] \
    || fail "internal Hungarian i18n bundle smoke failed"
  log "internal Hungarian i18n bundle smoke passed"
}


if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
MODE="${1:-}"
[[ -n "${MODE}" ]] || {
  usage >&2
  exit 2
}
shift

while (( $# > 0 )); do
  case "$1" in
    --expected-version)
      [[ $# -ge 2 ]] || fail "--expected-version requires a value"
      EXPECTED_VERSION="$2"
      shift 2
      ;;
    --timeout-seconds)
      [[ $# -ge 2 ]] || fail "--timeout-seconds requires a value"
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --leave-running-on-failure)
      STOP_ON_FAILURE=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

case "${MODE}" in
  restart-and-check|check|diagnostics)
    ;;
  *)
    fail "unknown mode: ${MODE}"
    ;;
esac
[[ "${TIMEOUT_SECONDS}" =~ ^[1-9][0-9]{0,3}$ ]] \
  || fail "timeout must be an integer between 1 and 9999 seconds"
if [[ -n "${EXPECTED_VERSION}" ]]; then
  [[ "${EXPECTED_VERSION}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)([-~]qa\.[1-9][0-9]*)?$ ]] \
    || fail "expected version must be a SemVer core or QA prerelease"
fi
[[ "${COMPOSE_PROJECT}" =~ ^[a-zA-Z0-9_.-]+$ ]] \
  || fail "invalid Compose project name"

if [[ "${MODE}" == diagnostics ]]; then
  run_diagnostics
  exit 0
fi
if (( EUID != 0 )) \
    && ! is_truthy "${MYSCOUTEE_QUALIFY_ALLOW_NON_ROOT_FOR_TESTS:-false}"; then
  fail "deployment qualification must run as root"
fi
for command_name in docker dpkg-query systemctl timeout; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "missing command: ${command_name}"
done

trap on_error ERR
qualification_started_at="${SECONDS}"
verify_installed_version

if [[ "${MODE}" == restart-and-check ]]; then
  stage="service restart"
  log "restarting ${SERVICE_NAME}"
  systemctl restart "${SERVICE_NAME}"
fi

stage="service readiness"
wait_for_service

stage="container readiness"
wait_for_deployment_containers

stage="Mongo and application smoke"
run_application_smoke "${qualification_started_at}"

stage="i18n bundle smoke"
check_i18n_bundle

stage="restart-loop check"
check_restart_loops

stage="project status"
project_qualification_report

log "deployment qualification passed"
