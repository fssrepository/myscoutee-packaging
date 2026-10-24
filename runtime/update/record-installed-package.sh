#!/usr/bin/env bash
# Retain package identity only; never copy application data or the package payload.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/release-project.sh"
release_project_load "${SCRIPT_DIR}" "$(stat -c %u "${BASH_SOURCE[0]}")" || {
  echo 'The package-owned release project policy is missing or unsafe.' >&2; exit 1;
}
umask 077
[[ ${EUID} == 0 && $# == 1 && -f "$1" && ! -L "$1" ]] || exit 1
artifact="$1"
version="$(dpkg-query -W -f='${Version}' "$RELEASE_PROJECT_NAME")"
[[ "$(dpkg-deb -f "$artifact" Package)" == "$RELEASE_PROJECT_NAME" && "$(dpkg-deb -f "$artifact" Version)" == "$version" ]] || exit 1
manifest=${RELEASE_PROJECT_ROOT}/packaging/IMAGE-MANIFEST.json
[[ -f "$manifest" && ! -L "$manifest" ]] || exit 1
packaged_manifest="$(dpkg-deb --fsys-tarfile "$artifact" | tar -xOf - .${RELEASE_PROJECT_ROOT}/packaging/IMAGE-MANIFEST.json | sha256sum)"
[[ "${packaged_manifest%% *}" == "$(sha256sum "$manifest" | cut -d' ' -f1)" ]] || exit 1
runtime=/var/lib/${RELEASE_PROJECT_NAME}/update/runtime
[[ -d "$runtime" && ! -L "$runtime" && "$(stat -c %u "$runtime")" == 0 ]] || exit 1
temporary="$(mktemp "$runtime/.installed-package.XXXXXX")"
trap 'test ! -f "$temporary" || unlink "$temporary"' EXIT
jq -n --arg version "${version/\~/-}" --arg sha "sha256:$(sha256sum "$artifact" | cut -d' ' -f1)" \
  '{version:$version,artifactSha256:$sha}' > "$temporary"
chown "+0:+${RELEASE_PROJECT_GID}" -- "$temporary"
chmod 0640 "$temporary"
sync -f "$temporary"
mv -T "$temporary" "$runtime/installed-package.json"
sync -f "$runtime"
