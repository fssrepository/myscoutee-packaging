#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}"
# The package builder is runtime-source packaging logic, not a release wrapper.
PACKAGE_SCRIPT="${SCRIPT_DIR}/package-production.sh"
DIST_DIR="${MYSCOUTEE_DIST_DIR:-${REPO_ROOT}/build/packaging/dist}"

if [ ! -f "${PACKAGE_SCRIPT}" ]; then
  echo "Package script not found: ${PACKAGE_SCRIPT}" >&2
  exit 1
fi

echo "Building MyScoutee Debian package and Operator helper bundle..."
bash "${PACKAGE_SCRIPT}" "$@"

project_name="$(jq -er .packageName "${REPO_ROOT}/config/packaging/release-project.json")"
latest_deb="$(find "${DIST_DIR}" -maxdepth 1 -type f -name "${project_name}_*_*.deb" -printf '%T@ %p\n' 2>/dev/null \
  | sort -nr \
  | awk 'NR == 1 { print $2 }')"

if [ -z "${latest_deb}" ]; then
  echo "Debian package was not found under ${DIST_DIR}." >&2
  exit 1
fi

package_version="$(dpkg-deb -f "${latest_deb}" Version | tr '~' '-')"
client_tools="${DIST_DIR}/${project_name}-client-tools_${package_version}.tar.gz"
if [ ! -f "${client_tools}" ]; then
  echo "Operator helper bundle was not found: ${client_tools}" >&2
  exit 1
fi

write_checksum() {
  artifact="$1"
  artifact_dir="$(dirname "${artifact}")"
  artifact_name="$(basename "${artifact}")"
  checksum_file="${artifact}.sha256"
  checksum_tmp="$(mktemp "${checksum_file}.tmp.XXXXXX")"
  if ! (cd "${artifact_dir}" && sha256sum "${artifact_name}") > "${checksum_tmp}"; then
    rm -f -- "${checksum_tmp}"
    return 1
  fi
  chmod 0644 "${checksum_tmp}"
  mv -f -- "${checksum_tmp}" "${checksum_file}"
  echo "SHA-256 ready: ${checksum_file}"
}

write_checksum "${latest_deb}"
write_checksum "${client_tools}"

echo "Debian package ready: ${latest_deb}"
