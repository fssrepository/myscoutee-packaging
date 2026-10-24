#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}"
PACKAGING="${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging"
NODE="$(command -v node)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/dist"
for command in docker dpkg-deb npm node java; do
  printf '#!/bin/sh\necho "Unexpected application build command" >&2\nexit 99\n' > "${TEST_ROOT}/bin/${command}"
  chmod 0755 "${TEST_ROOT}/bin/${command}"
done
printf 'existing DEB must remain unchanged\n' > "${TEST_ROOT}/dist/myscoutee_1.0.0_amd64.deb"
before="$(sha256sum "${TEST_ROOT}/dist/myscoutee_1.0.0_amd64.deb")"
PATH="${TEST_ROOT}/bin:${PATH}" MYSCOUTEE_VERSION=1.0.0 MYSCOUTEE_DIST_DIR="${TEST_ROOT}/dist" \
  "$NODE" "${PACKAGING}/bin/packaging.mjs" --project-root "$REPO_ROOT" client-tools
[[ "$(sha256sum "${TEST_ROOT}/dist/myscoutee_1.0.0_amd64.deb")" == "${before}" ]]
archive="${TEST_ROOT}/dist/myscoutee-client-tools_1.0.0.tar.gz"
(cd "${TEST_ROOT}/dist" && sha256sum -c myscoutee-client-tools_1.0.0.tar.gz.sha256)
[[ "$(tar -xOzf "${archive}" ./VERSION)" == 1.0.0 ]]
tar -xOzf "${archive}" ./prepare-debian13-minimal.sh \
  | cmp - "${PACKAGING}/client-tools/prepare-debian13-minimal.sh"
for helper in install-temporary-frontend.sh install-temporary-image.sh; do
  tar -xOzf "${archive}" "./${helper}" | cmp - "${PACKAGING}/client-tools/${helper}"
done
tar -xOzf "${archive}" ./release-project.sh | cmp - "${REPO_ROOT}/build/scripts/release-project.sh"
tar -xOzf "${archive}" ./release-project.json | cmp - "${REPO_ROOT}/config/packaging/release-project.json"
tar -xOzf "${archive}" ./install.env.example | cmp - "${REPO_ROOT}/config/packaging/client-tools/install.env.example"
if tar -tzf "${archive}" | grep -Fxq './install.env'; then
  echo "Local credentials must not be packaged" >&2
  exit 1
fi
first_hash="$(sha256sum "${archive}")"
MYSCOUTEE_VERSION=1.0.0 MYSCOUTEE_DIST_DIR="${TEST_ROOT}/dist" \
  "$NODE" "${PACKAGING}/bin/packaging.mjs" --project-root "$REPO_ROOT" client-tools
[[ "$(sha256sum "${archive}")" == "${first_hash}" ]]

# A selected archive must never smuggle a local config or traversal through
# its manifest. Exercise the actual builder in an isolated source layout.
fixture="${TEST_ROOT}/selection-source"
mkdir -p "$fixture/config/packaging/release" "$fixture/config/packaging/client-tools"
cp "${REPO_ROOT}/config/packaging/release/settings.json" "$fixture/config/packaging/release/"
cp "${REPO_ROOT}/config/packaging/package.json" "$fixture/config/packaging/"
install -m 0644 "${REPO_ROOT}/config/packaging/release-project.json" "$fixture/config/packaging/release-project.json"
for forbidden in install.env secrets.json ../outside.sh; do
  jq -n --arg forbidden "$forbidden" '["install.sh","verify-release.sh","remote-transport.sh",$forbidden]' \
    > "$fixture/config/packaging/client-tools/manifest.json"
  if MYSCOUTEE_VERSION=1.0.0 MYSCOUTEE_DIST_DIR="$fixture/dist" \
      "$NODE" "${PACKAGING}/bin/packaging.mjs" --project-root "$fixture" client-tools >"$fixture/rejected.log" 2>&1; then
    echo "Archive accepted forbidden manifest input: $forbidden" >&2; exit 1
  fi
  grep -Fxq 'Invalid client-tools selection.' "$fixture/rejected.log"
  [[ ! -e "$fixture/dist/myscoutee-client-tools_1.0.0.tar.gz" ]]
done
echo "Client-tools-only packaging passed: reproducible archive; DEB unchanged; no application build."
