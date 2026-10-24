#!/usr/bin/env bash
set -euo pipefail

# Build only the small client archive. No DEB, images or application build.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}"
CLIENT_TOOLS_SOURCE="${SCRIPT_DIR}/../../client-tools"
source "${SCRIPT_DIR}/../lib/release-config.sh"
release_config_load "${REPO_ROOT}"
VERSION="${MYSCOUTEE_VERSION:-$(release_config_value .build.fallbackVersion)}"
DIST_DIR="${MYSCOUTEE_DIST_DIR:-${REPO_ROOT}/build/packaging/dist}"
if [[ ! "${VERSION}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-qa\.[1-9][0-9]*)?$ ]]; then
  echo "MYSCOUTEE_VERSION must be a SemVer core or QA prerelease." >&2
  exit 1
fi
source "${SCRIPT_DIR}/../lib/release-project.sh"
release_project_load "${REPO_ROOT}/config/packaging" "$(id -u)" || {
  echo 'Invalid release project policy.' >&2; exit 1;
}
install -d "${DIST_DIR}"
WORK_DIR="$(mktemp -d "${DIST_DIR}/.client-tools.XXXXXX")"
trap 'rm -rf -- "${WORK_DIR}"' EXIT
install -d "${WORK_DIR}/payload/verify-deployment"
selection="${REPO_ROOT}/config/packaging/client-tools/manifest.json"
jq -e 'type == "array" and length > 0 and length == (unique | length)
  and all(.[]; type == "string" and
    (. == "README.md" or . == "install.env.example" or test("^[A-Za-z0-9][A-Za-z0-9_-]*\\.sh$")))
  and (index("install.sh") != null) and (index("verify-release.sh") != null)
  and (index("remote-transport.sh") != null)' "$selection" >/dev/null || {
  echo 'Invalid client-tools selection.' >&2; exit 1;
}
while IFS= read -r helper; do
  helper_path="${CLIENT_TOOLS_SOURCE}/${helper}"
  if [[ "$helper" == install.env.example ]]; then
    helper_path="${REPO_ROOT}/config/packaging/client-tools/${helper}"
  fi
  [[ -f "$helper_path" && ! -L "$helper_path" ]] || {
    echo "Client helper must be a regular file: ${helper}" >&2; exit 1;
  }
  install -m 0644 "$helper_path" "${WORK_DIR}/payload/${helper}"
done < <(jq -r '.[]' "$selection")
cp -a "${SCRIPT_DIR}/../../verification/public/." "${WORK_DIR}/payload/verify-deployment/"
install -m 0644 "${REPO_ROOT}/config/packaging/verification.json" "${WORK_DIR}/payload/verify-deployment/project.json"
install -m 0644 "${SCRIPT_DIR}/../lib/release-project.sh" "${WORK_DIR}/payload/release-project.sh"
install -m 0644 "$RELEASE_PROJECT_POLICY" "${WORK_DIR}/payload/release-project.json"
install -m 0644 "${CLIENT_TOOLS_SOURCE}/client-project.sh" "${WORK_DIR}/payload/client-project.sh"
printf '%s\n' "${VERSION}" > "${WORK_DIR}/payload/VERSION"
find "${WORK_DIR}/payload" -type d -exec chmod 0755 {} +
find "${WORK_DIR}/payload" -type f -exec chmod 0644 {} +
find "${WORK_DIR}/payload" -type f -name '*.sh' -exec chmod 0755 {} +
chmod 0755 "${WORK_DIR}/payload/verify-deployment/run.mjs"
archive="${RELEASE_PROJECT_NAME}-client-tools_${VERSION}.tar.gz"
tar --sort=name --mtime="@${SOURCE_DATE_EPOCH:-0}" --owner=0 --group=0 --numeric-owner \
  -C "${WORK_DIR}/payload" -cf - . | gzip -n > "${WORK_DIR}/${archive}"
chmod 0644 "${WORK_DIR}/${archive}"
(cd "${WORK_DIR}" && sha256sum "${archive}" > "${archive}.sha256")
chmod 0644 "${WORK_DIR}/${archive}.sha256"
mv -f -- "${WORK_DIR}/${archive}" "${DIST_DIR}/${archive}"
mv -f -- "${WORK_DIR}/${archive}.sha256" "${DIST_DIR}/${archive}.sha256"
echo "Client tools ready: ${DIST_DIR}/${archive}"
