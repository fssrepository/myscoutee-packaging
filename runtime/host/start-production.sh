#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/release-project.sh"
release_project_load "${SCRIPT_DIR}" "$(stat -c %u "${BASH_SOURCE[0]}")" || {
  echo 'The package-owned release project policy is missing or unsafe.' >&2; exit 1;
}
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
SERVER_DIR="${REPO_ROOT}/server"

read_version() {
  sed -n 's/^MYSCOUTEE_VERSION=//p' "${SERVER_DIR}/.env" | head -n 1
}

VERSION="${MYSCOUTEE_VERSION:-$(read_version)}"
VERSION="${VERSION:-$(jq -er '.hostTools.startupFallbackVersion' "$RELEASE_PROJECT_POLICY")}"
if [[ ! "${VERSION}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-qa\.[1-9][0-9]*)?$ ]]; then
  echo "MYSCOUTEE_VERSION must be a SemVer core or QA prerelease such as 1.0.0-qa.1." >&2
  exit 1
fi

export MYSCOUTEE_VERSION="${VERSION}"
release_project_export_images "${VERSION}"

MYSCOUTEE_SERVER_DIR="${SERVER_DIR}" "${SCRIPT_DIR}/myscoutee-compose.sh" up -d
