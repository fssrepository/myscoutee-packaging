#!/usr/bin/env bash
# Source-checkout release builder; deliberately not installed by the DEB.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}"
source "${SCRIPT_DIR}/../lib/release-config.sh"
release_config_load "${REPO_ROOT}"
SERVER_DIR="${REPO_ROOT}/server"
FRONTEND_DIR="${REPO_ROOT}/frontend"

read_version() {
  sed -n 's/^MYSCOUTEE_VERSION=//p' "${SERVER_DIR}/.env" | head -n 1
}

VERSION="${MYSCOUTEE_VERSION:-$(read_version)}"
VERSION="${VERSION:-$(release_config_value .build.fallbackVersion)}"
if [[ ! "${VERSION}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-qa\.[1-9][0-9]*)?$ ]]; then
  echo "MYSCOUTEE_VERSION must be a SemVer core or QA prerelease such as 1.0.0-qa.1." >&2
  exit 1
fi

export MYSCOUTEE_VERSION="${VERSION}"
source "${SCRIPT_DIR}/../lib/release-project.sh"
release_project_load "${REPO_ROOT}/config/packaging" "$(id -u)" || {
  echo 'Invalid release project policy.' >&2; exit 1;
}
release_project_export_images "${VERSION}" false
export MYSCOUTEE_API_UID="$RELEASE_PROJECT_UID" MYSCOUTEE_API_GID="$RELEASE_PROJECT_GID"

BUILD_FRONTEND="${BUILD_FRONTEND:-true}"
BUILD_BACKEND="${BUILD_BACKEND:-true}"
BUILD_IMAGES="${BUILD_IMAGES:-true}"
FRONTEND_BUILD_SCRIPT="${FRONTEND_BUILD_SCRIPT:-$(release_config_value .build.frontendScript)}"

if [[ "${BUILD_FRONTEND}" == "true" ]]; then
  (cd "${FRONTEND_DIR}" && npm run "${FRONTEND_BUILD_SCRIPT}")
  # Production nginx consumes frontend/prod through its named build context.
  # The dev nginx output is owned exclusively by the dev synchronizer.
fi

if [[ "${BUILD_BACKEND}" == "true" ]]; then
  (cd "${SERVER_DIR}" && ./gradlew "$(release_config_value .build.backendTask)")
fi

if [[ "${BUILD_IMAGES}" == "true" ]]; then
  shared_nginx="${NGINX_NATIVE_IMAGE:-$(release_config_value .build.nginxNativeImage)}"
  docker pull "${shared_nginx}"
  # The offline package retains its existing inventory alias; no extra image layer.
  docker tag "${shared_nginx}" "${NGINX_BASE_IMAGE}"
  python3 "${SCRIPT_DIR}/render-nginx-routes.py"

  (cd "${SERVER_DIR}" && docker compose -f docker-compose-prod.yml build)
fi

echo "Built ${RELEASE_PROJECT_NAME} production artifacts for version ${VERSION}."
