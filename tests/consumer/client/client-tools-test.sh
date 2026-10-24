#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}"
CLIENT_TOOLS_DIR="${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/client-tools"
export MYSCOUTEE_PACKAGING_PROJECT_ROOT="$REPO_ROOT"
TEST_ROOT="$(mktemp -d /tmp/myscoutee-operator-client-tools-test.XXXXXX)"
FAKE_BIN="${TEST_ROOT}/bin"
COMMAND_LOG="${TEST_ROOT}/commands.log"
CONFIG_FILE="${TEST_ROOT}/install.env"
DEB_FILE="${TEST_ROOT}/myscoutee_1.0.0_amd64.deb"
SSH_SECRET="ssh-test-secret-do-not-log"
SUDO_SECRET="sudo-test-secret-do-not-log"

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  echo "Client-tools test failed: $1" >&2
  exit 1
}

mkdir -p "${FAKE_BIN}"
: > "${COMMAND_LOG}"
: > "${DEB_FILE}"

cat > "${FAKE_BIN}/dpkg-deb" <<'SCRIPT'
#!/usr/bin/env bash
case "${3:-}" in
  Package)
    printf '%s\n' "${OPERATOR_CLIENT_TEST_PACKAGE_NAME:-myscoutee}"
    ;;
  Version)
    printf '1.0.0\n'
    ;;
  *)
    exit 2
    ;;
esac
SCRIPT

cat > "${FAKE_BIN}/dpkg" <<'SCRIPT'
#!/usr/bin/env bash
[[ "${1:-}" == "--validate-version" ]] || exit 2
SCRIPT

cat > "${FAKE_BIN}/setsid" <<'SCRIPT'
#!/usr/bin/env bash
[[ "${1:-}" == "-w" ]] && shift
exec "$@"
SCRIPT

cat > "${FAKE_BIN}/ps" <<'SCRIPT'
#!/usr/bin/env bash
# Never inspect or terminate a real SSH tunnel during this contract test.
exit 0
SCRIPT

cat > "${FAKE_BIN}/sudo" <<'SCRIPT'
#!/usr/bin/env bash
printf 'sudo\t%s\n' "$*" >> "${OPERATOR_CLIENT_TEST_LOG:?}"
exit 99
SCRIPT

cat > "${FAKE_BIN}/node" <<'SCRIPT'
#!/usr/bin/env bash
printf 'node\t%s\n' "$*" >> "${OPERATOR_CLIENT_TEST_LOG:?}"
exit 97
SCRIPT

cat > "${FAKE_BIN}/scp" <<'SCRIPT'
#!/usr/bin/env bash
printf 'scp\t%s\n' "$*" >> "${OPERATOR_CLIENT_TEST_LOG:?}"
SCRIPT

cat > "${FAKE_BIN}/ssh" <<'SCRIPT'
#!/usr/bin/env bash
remote_command="${*: -1}"
printf 'ssh\t%s\n' "$*" >> "${OPERATOR_CLIENT_TEST_LOG:?}"
if [[ "${remote_command}" == *"sudo -S"* ]]; then
  IFS= read -r supplied_password || true
  [[ "${supplied_password}" == "${OPERATOR_CLIENT_TEST_SUDO_SECRET:?}" ]] \
    || exit 91
  printf 'sudo-stdin\tpresent\n' >> "${OPERATOR_CLIENT_TEST_LOG:?}"
fi
if [[ "${remote_command}" == *"Status-Abbrev"* ]]; then
  exit 1
fi
if [[ "${remote_command}" == *"dpkg-query"* ]]; then
  printf '%s' "${OPERATOR_CLIENT_TEST_INSTALLED_VERSION:-1.0.0}"
fi
SCRIPT

chmod 0755 \
  "${FAKE_BIN}/dpkg-deb" \
  "${FAKE_BIN}/dpkg" \
  "${FAKE_BIN}/setsid" \
  "${FAKE_BIN}/ps" \
  "${FAKE_BIN}/sudo" \
  "${FAKE_BIN}/node" \
  "${FAKE_BIN}/scp" \
  "${FAKE_BIN}/ssh"

cat > "${CONFIG_FILE}" <<ENV
REMOTE_HOST=192.0.2.10
REMOTE_USER=operator
REMOTE_PORT=22
REMOTE_PASSWORD=${SSH_SECRET}
REMOTE_SUDO_PASSWORD=${SUDO_SECRET}
REMOTE_DEB_PATH=/tmp/myscoutee.deb
RUN_APT_UPDATE=false
START_SERVICE=true
STOP_ON_FAILURE=true
QUALIFY_TIMEOUT_SECONDS=45
LOCAL_FORWARD_PORTS=80,443
ALLOW_UNSIGNED_LOCAL_PACKAGE=true
VERIFY_DEPLOYMENT_URL=https://deployment.example
ENV
chmod 0600 "${CONFIG_FILE}"

INSTALL_OUTPUT="${TEST_ROOT}/install.out"
PATH="${FAKE_BIN}:/usr/bin:/bin" \
CONFIG_FILE="${CONFIG_FILE}" \
OPERATOR_CLIENT_TEST_LOG="${COMMAND_LOG}" \
OPERATOR_CLIENT_TEST_SUDO_SECRET="${SUDO_SECRET}" \
  "${CLIENT_TOOLS_DIR}/install.sh" "${DEB_FILE}" > "${INSTALL_OUTPUT}"

grep -Fq $'scp\t' "${COMMAND_LOG}" \
  || fail "install wrapper did not upload the Debian package"
grep -Fq "'dpkg' '--unpack' '/tmp/myscoutee.deb'" \
  "${COMMAND_LOG}" \
  || fail "same-version install did not unpack the replacement payload"
grep -Fq \
  "'env' 'DEBIAN_FRONTEND=noninteractive' 'apt-get' '-f' 'install' '-y' '--no-remove'" \
  "${COMMAND_LOG}" \
  || fail "same-version install did not configure through no-remove APT repair"
if grep -Eq "'apt-get' '(remove|purge)'" "${COMMAND_LOG}"; then
  fail "same-version install removed the package"
fi
grep -Fq \
  "'/opt/myscoutee/packaging/scripts/qualify-deployment.sh' 'restart-and-check' '--expected-version' '1.0.0' '--timeout-seconds' '45'" \
  "${COMMAND_LOG}" \
  || fail "install wrapper did not delegate to the package qualifier"
grep -Fq $'sudo-stdin\tpresent' "${COMMAND_LOG}" \
  || fail "sudo password was not supplied over SSH stdin"
if grep -R -Fq -- "${SSH_SECRET}" "${COMMAND_LOG}" "${INSTALL_OUTPUT}"; then
  fail "SSH password leaked into process arguments or output"
fi
if grep -R -Fq -- "${SUDO_SECRET}" "${COMMAND_LOG}" "${INSTALL_OUTPUT}"; then
  fail "sudo password leaked into process arguments or output"
fi
grep -Fq \
  "npm --prefix \"${REPO_ROOT}/config/packaging\" run verify -- --url https://deployment.example --expected-version 1.0.0" \
  "${INSTALL_OUTPUT}" \
  || fail "source-layout wrapper did not print its configured deployment verifier"
if grep -Fq $'node\t' "${COMMAND_LOG}"; then
  fail "install wrapper executed deployment verification"
fi

# The checkout default reads the relocated config without a CONFIG_FILE override.
SOURCE_FIXTURE="${TEST_ROOT}/source"
install -d "${SOURCE_FIXTURE}/packaging/client-tools" "${SOURCE_FIXTURE}/packaging/release/lib" \
  "${SOURCE_FIXTURE}/config/packaging/client-tools"
for helper in install.sh remote-transport.sh client-project.sh; do
  install -m 0755 "${CLIENT_TOOLS_DIR}/${helper}" "${SOURCE_FIXTURE}/packaging/client-tools/${helper}"
done
install -m 0644 "${CLIENT_TOOLS_DIR}/../release/lib/release-project.sh" "${SOURCE_FIXTURE}/packaging/release/lib/"
install -m 0644 "${REPO_ROOT}/config/packaging/release-project.json" "${SOURCE_FIXTURE}/config/packaging/"
install -m 0600 "${CONFIG_FILE}" "${SOURCE_FIXTURE}/config/packaging/client-tools/install.env"
: > "${COMMAND_LOG}"
env -u CONFIG_FILE PATH="${FAKE_BIN}:/usr/bin:/bin" \
  MYSCOUTEE_PACKAGING_PROJECT_ROOT="${SOURCE_FIXTURE}" \
  OPERATOR_CLIENT_TEST_LOG="${COMMAND_LOG}" OPERATOR_CLIENT_TEST_SUDO_SECRET="${SUDO_SECRET}" \
  bash "${SOURCE_FIXTURE}/packaging/client-tools/install.sh" "${DEB_FILE}" > "${TEST_ROOT}/source-default.out"
grep -Fq '/config/packaging/client-tools/install.env' "${TEST_ROOT}/source-default.out" \
  || fail "source-layout wrapper did not load the relocated default config"

BUNDLE_DIR="${TEST_ROOT}/client-tools-bundle"
install -d "${BUNDLE_DIR}"
for bundle_helper in \
  install.sh \
  purge.sh \
  remote-transport.sh \
  verify-release.sh; do
  install -m 0755 \
    "${CLIENT_TOOLS_DIR}/${bundle_helper}" \
    "${BUNDLE_DIR}/${bundle_helper}"
done
install -m 0644 "${CLIENT_TOOLS_DIR}/client-project.sh" "${BUNDLE_DIR}/client-project.sh"
install -m 0644 "${REPO_ROOT}/build/scripts/release-project.sh" "${BUNDLE_DIR}/release-project.sh"
install -m 0644 "${REPO_ROOT}/config/packaging/release-project.json" "${BUNDLE_DIR}/release-project.json"
cp -a "${CLIENT_TOOLS_DIR}/../verification/public" \
  "${BUNDLE_DIR}/verify-deployment"
install -m 0644 "${REPO_ROOT}/config/packaging/verification.json" "${BUNDLE_DIR}/verify-deployment/project.json"
: > "${COMMAND_LOG}"
BUNDLE_INSTALL_OUTPUT="${TEST_ROOT}/bundle-install.out"
PATH="${FAKE_BIN}:/usr/bin:/bin" \
CONFIG_FILE="${CONFIG_FILE}" \
OPERATOR_CLIENT_TEST_LOG="${COMMAND_LOG}" \
OPERATOR_CLIENT_TEST_SUDO_SECRET="${SUDO_SECRET}" \
  env -u MYSCOUTEE_PACKAGING_PROJECT_ROOT "${BUNDLE_DIR}/install.sh" "${DEB_FILE}" > "${BUNDLE_INSTALL_OUTPUT}"
BUNDLE_DEPLOYMENT_VERIFIER="$(
  cd "${BUNDLE_DIR}/verify-deployment" && pwd
)/run.mjs"
grep -Fq \
  "node \"${BUNDLE_DEPLOYMENT_VERIFIER}\" --url https://deployment.example --expected-version 1.0.0" \
  "${BUNDLE_INSTALL_OUTPUT}" \
  || fail "release-bundle wrapper did not print its deployment verifier"
if grep -Fq $'node\t' "${COMMAND_LOG}"; then
  fail "release-bundle wrapper executed deployment verification"
fi

SIGNED_REQUIRED_CONFIG="${TEST_ROOT}/signed-required.env"
sed '/^ALLOW_UNSIGNED_LOCAL_PACKAGE=/d' \
  "${CONFIG_FILE}" > "${SIGNED_REQUIRED_CONFIG}"
chmod 0600 "${SIGNED_REQUIRED_CONFIG}"
: > "${COMMAND_LOG}"
if PATH="${FAKE_BIN}:/usr/bin:/bin" \
    CONFIG_FILE="${SIGNED_REQUIRED_CONFIG}" \
    OPERATOR_CLIENT_TEST_LOG="${COMMAND_LOG}" \
    OPERATOR_CLIENT_TEST_SUDO_SECRET="${SUDO_SECRET}" \
      "${CLIENT_TOOLS_DIR}/install.sh" "${DEB_FILE}" >/dev/null 2>&1; then
  fail "unsigned package was accepted without the explicit local override"
fi
if grep -Fq $'scp\t' "${COMMAND_LOG}"; then
  fail "unsigned package was uploaded before release verification"
fi

PARTIAL_RELEASE_CONFIG="${TEST_ROOT}/partial-release.env"
cp "${CONFIG_FILE}" "${PARTIAL_RELEASE_CONFIG}"
printf '%s\n' 'RELEASE_MANIFEST_PATH=/tmp/release.json' \
  >> "${PARTIAL_RELEASE_CONFIG}"
chmod 0600 "${PARTIAL_RELEASE_CONFIG}"
: > "${COMMAND_LOG}"
if PATH="${FAKE_BIN}:/usr/bin:/bin" \
    CONFIG_FILE="${PARTIAL_RELEASE_CONFIG}" \
    OPERATOR_CLIENT_TEST_LOG="${COMMAND_LOG}" \
    OPERATOR_CLIENT_TEST_SUDO_SECRET="${SUDO_SECRET}" \
      "${CLIENT_TOOLS_DIR}/install.sh" "${DEB_FILE}" >/dev/null 2>&1; then
  fail "partially configured release verification was bypassed"
fi
if grep -Fq $'scp\t' "${COMMAND_LOG}"; then
  fail "partially verified package was uploaded"
fi

: > "${COMMAND_LOG}"
PATH="${FAKE_BIN}:/usr/bin:/bin" \
CONFIG_FILE="${CONFIG_FILE}" \
OPERATOR_CLIENT_TEST_LOG="${COMMAND_LOG}" \
OPERATOR_CLIENT_TEST_SUDO_SECRET="${SUDO_SECRET}" \
  "${CLIENT_TOOLS_DIR}/purge.sh" >/dev/null
grep -Fq "'apt-get' 'purge' '-y' 'myscoutee'" "${COMMAND_LOG}" \
  || fail "purge wrapper did not delegate to apt-get purge"
if grep -Eq 'docker|/var/lib/myscoutee|/var/backups/myscoutee' "${COMMAND_LOG}"; then
  fail "purge wrapper duplicated package-owned state cleanup"
fi

INSECURE_CONFIG="${TEST_ROOT}/insecure.env"
cp "${CONFIG_FILE}" "${INSECURE_CONFIG}"
chmod 0644 "${INSECURE_CONFIG}"
if PATH="${FAKE_BIN}:/usr/bin:/bin" \
    CONFIG_FILE="${INSECURE_CONFIG}" \
    OPERATOR_CLIENT_TEST_LOG="${COMMAND_LOG}" \
    OPERATOR_CLIENT_TEST_SUDO_SECRET="${SUDO_SECRET}" \
      "${CLIENT_TOOLS_DIR}/install.sh" "${DEB_FILE}" >/dev/null 2>&1; then
  fail "password-bearing world-readable config was accepted"
fi

UNSAFE_CONFIG="${TEST_ROOT}/unsafe-path.env"
sed 's|^REMOTE_DEB_PATH=.*|REMOTE_DEB_PATH=/tmp/../unsafe.deb|' \
  "${CONFIG_FILE}" > "${UNSAFE_CONFIG}"
chmod 0600 "${UNSAFE_CONFIG}"
if PATH="${FAKE_BIN}:/usr/bin:/bin" \
    CONFIG_FILE="${UNSAFE_CONFIG}" \
    OPERATOR_CLIENT_TEST_LOG="${COMMAND_LOG}" \
    OPERATOR_CLIENT_TEST_SUDO_SECRET="${SUDO_SECRET}" \
      "${CLIENT_TOOLS_DIR}/install.sh" "${DEB_FILE}" >/dev/null 2>&1; then
  fail "unsafe remote Debian path was accepted"
fi

TUNNEL_OUTPUT="${TEST_ROOT}/tunnel.out"
: > "${COMMAND_LOG}"
PATH="${FAKE_BIN}:/usr/bin:/bin" \
CONFIG_FILE="${CONFIG_FILE}" \
LOCAL_FORWARD_PORTS_OVERRIDE=18080:80,18443:443 \
OPERATOR_CLIENT_TEST_LOG="${COMMAND_LOG}" \
OPERATOR_CLIENT_TEST_SUDO_SECRET="${SUDO_SECRET}" \
  "${CLIENT_TOOLS_DIR}/forward-localhost.sh" > "${TUNNEL_OUTPUT}"
grep -Fq -- '-L 127.0.0.1:18080:127.0.0.1:80' "${COMMAND_LOG}" \
  || fail "high-port HTTP mapping did not reach SSH"
grep -Fq -- '-L 127.0.0.1:18443:127.0.0.1:443' "${COMMAND_LOG}" \
  || fail "high-port HTTPS mapping did not reach SSH"
if grep -Fq -- '-L 127.0.0.1:80:' "${COMMAND_LOG}" \
    || grep -Fq -- '-L 127.0.0.1:443:' "${COMMAND_LOG}"; then
  fail "runtime port override did not replace install.env defaults"
fi
if grep -Fq $'sudo\t' "${COMMAND_LOG}"; then
  fail "non-privileged high-port tunnel invoked local sudo"
fi
if grep -R -Fq -- "${SSH_SECRET}" "${COMMAND_LOG}" "${TUNNEL_OUTPUT}" \
    || grep -R -Fq -- "${SUDO_SECRET}" "${COMMAND_LOG}" "${TUNNEL_OUTPUT}"; then
  fail "a tunnel helper password leaked into process arguments or output"
fi

: > "${COMMAND_LOG}"
PATH="${FAKE_BIN}:/usr/bin:/bin" \
CONFIG_FILE="${CONFIG_FILE}" \
LOCAL_FORWARD_PORTS_OVERRIDE=18081 \
OPERATOR_CLIENT_TEST_LOG="${COMMAND_LOG}" \
OPERATOR_CLIENT_TEST_SUDO_SECRET="${SUDO_SECRET}" \
  "${CLIENT_TOOLS_DIR}/forward-localhost.sh" >/dev/null
grep -Fq -- '-L 127.0.0.1:18081:127.0.0.1:18081' "${COMMAND_LOG}" \
  || fail "bare forward port did not preserve same-port compatibility"

for invalid_mapping in \
  18080:80:1 \
  0:80 \
  18080:0 \
  65536:443 \
  18443:https \
  18080::80 \
  18080, \
  18080,,18443; do
  : > "${COMMAND_LOG}"
  if PATH="${FAKE_BIN}:/usr/bin:/bin" \
      CONFIG_FILE="${CONFIG_FILE}" \
      LOCAL_FORWARD_PORTS_OVERRIDE="${invalid_mapping}" \
      OPERATOR_CLIENT_TEST_LOG="${COMMAND_LOG}" \
      OPERATOR_CLIENT_TEST_SUDO_SECRET="${SUDO_SECRET}" \
        "${CLIENT_TOOLS_DIR}/forward-localhost.sh" >/dev/null 2>&1; then
    fail "invalid forward mapping was accepted: ${invalid_mapping}"
  fi
  if grep -Fq $'ssh\t' "${COMMAND_LOG}"; then
    fail "invalid forward mapping reached SSH: ${invalid_mapping}"
  fi
done

if grep -Fq 'REMOTE_SCRIPT' "${CLIENT_TOOLS_DIR}/install.sh" \
    || grep -Fq 'REMOTE_SCRIPT' "${CLIENT_TOOLS_DIR}/purge.sh"; then
  fail "Operator wrapper still embeds a remote host program"
fi

# Independent project identity must route only to its own host package/paths.
jq '.packageName = "sample-template"' "${BUNDLE_DIR}/release-project.json" > "${BUNDLE_DIR}/selected.json"
install -m 0644 "${BUNDLE_DIR}/selected.json" "${BUNDLE_DIR}/release-project.json"
: > "${COMMAND_LOG}"
PATH="${FAKE_BIN}:/usr/bin:/bin" CONFIG_FILE="${CONFIG_FILE}" \
OPERATOR_CLIENT_TEST_PACKAGE_NAME=sample-template \
OPERATOR_CLIENT_TEST_LOG="${COMMAND_LOG}" OPERATOR_CLIENT_TEST_SUDO_SECRET="${SUDO_SECRET}" \
  env -u MYSCOUTEE_PACKAGING_PROJECT_ROOT "${BUNDLE_DIR}/install.sh" "${DEB_FILE}" >/dev/null
grep -Fq "'/opt/sample-template/packaging/scripts/qualify-deployment.sh'" "${COMMAND_LOG}" \
  || fail "selected project did not use its own qualification path"
grep -Fq "'/opt/sample-template/packaging/scripts/record-installed-package.sh'" "${COMMAND_LOG}" \
  || fail "selected project did not record its own package"
: > "${COMMAND_LOG}"
PATH="${FAKE_BIN}:/usr/bin:/bin" CONFIG_FILE="${CONFIG_FILE}" \
OPERATOR_CLIENT_TEST_LOG="${COMMAND_LOG}" OPERATOR_CLIENT_TEST_SUDO_SECRET="${SUDO_SECRET}" \
  "${BUNDLE_DIR}/purge.sh" >/dev/null
grep -Fq "'apt-get' 'purge' '-y' 'sample-template'" "${COMMAND_LOG}" \
  || fail "selected project purge selected another package"
: > "${COMMAND_LOG}"
if PATH="${FAKE_BIN}:/usr/bin:/bin" CONFIG_FILE="${CONFIG_FILE}" \
OPERATOR_CLIENT_TEST_LOG="${COMMAND_LOG}" OPERATOR_CLIENT_TEST_SUDO_SECRET="${SUDO_SECRET}" \
  env -u MYSCOUTEE_PACKAGING_PROJECT_ROOT "${BUNDLE_DIR}/install.sh" "${DEB_FILE}" >/dev/null 2>&1; then
  fail "selected project accepted another package"
fi
[[ ! -s "${COMMAND_LOG}" ]] || fail "wrong package reached the remote transport"

echo "Client-tools tests passed."
