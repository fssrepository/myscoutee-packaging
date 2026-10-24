#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/release-project.sh"
release_project_load "${SCRIPT_DIR}" "$(stat -c %u "${BASH_SOURCE[0]}")" || {
  echo 'The package-owned release project policy is missing or unsafe.' >&2; exit 1;
}

SERVICE_NAME="${MYSCOUTEE_SERVICE_NAME:-${RELEASE_PROJECT_NAME}.service}"
COMPOSE_PROJECT="${MYSCOUTEE_COMPOSE_PROJECT:-server}"
COMPOSE_SCRIPT="${MYSCOUTEE_COMPOSE_SCRIPT:-${RELEASE_PROJECT_ROOT}/packaging/scripts/myscoutee-compose.sh}"
JOURNAL_LINES="${MYSCOUTEE_DIAGNOSTIC_JOURNAL_LINES:-120}"

if [[ ! "${COMPOSE_PROJECT}" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
  echo "Invalid MyScoutee Compose project name: ${COMPOSE_PROJECT}" >&2
  exit 2
fi
if [[ ! "${JOURNAL_LINES}" =~ ^[1-9][0-9]{0,3}$ ]]; then
  echo "Invalid diagnostic journal line count: ${JOURNAL_LINES}" >&2
  exit 2
fi

run_section() {
  local label="$1"
  shift

  printf '\n[diagnostics] %s\n' "${label}"
  "$@" || true
}

if command -v systemctl >/dev/null 2>&1; then
  run_section \
    "systemctl status ${SERVICE_NAME}" \
    systemctl --no-pager --full status "${SERVICE_NAME}"
fi

if command -v docker >/dev/null 2>&1; then
  run_section \
    "MyScoutee Docker containers" \
    docker ps -a \
      --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'

  if [[ -x "${COMPOSE_SCRIPT}" && ! -L "${COMPOSE_SCRIPT}" ]]; then
    run_section \
      "MyScoutee Compose status" \
      "${COMPOSE_SCRIPT}" ps
  fi
fi

if command -v journalctl >/dev/null 2>&1; then
  run_section \
    "recent ${SERVICE_NAME} journal" \
    journalctl -u "${SERVICE_NAME}" -n "${JOURNAL_LINES}" --no-pager
fi

