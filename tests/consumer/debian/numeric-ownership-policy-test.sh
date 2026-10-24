#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:-$PWD}"
TEST_ROOT="$(mktemp -d /tmp/myscoutee-numeric-ownership-test.XXXXXX)"

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT
mkdir -p "${TEST_ROOT}/debian"
python3 "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py" "${REPO_ROOT}/packaging" "${TEST_ROOT}/debian" --hook all

fail() {
  echo "Numeric ownership policy test failed: $1" >&2
  exit 1
}

join_shell_continuations() {
  sed \
    -e ':join' \
    -e '/\\[[:space:]]*$/ {
      N
      s/\\[[:space:]]*\n[[:space:]]*/ /
      b join
    }' \
    "$1"
}

scan_script() {
  local script="$1"
  local logical_lines="${TEST_ROOT}/logical-lines"

  join_shell_continuations "${script}" > "${logical_lines}"
  if grep -Eq \
      '(^|[;&|()[:space:]])install[[:space:]][^;]*[[:space:]](-o|-g|--owner(=|[[:space:]])|--group(=|[[:space:]]))' \
      "${logical_lines}"; then
    fail "${script#${REPO_ROOT}/} uses install ownership options"
  fi
  if grep -Eq \
      '(chown|chgrp)[[:space:]][^;]*(root:)?("\$\{[A-Z0-9_]*(UID|GID|USER_ID|GROUP_ID)(:-[0-9]+)?\}|root:"\$\{[A-Z0-9_]*(GID|GROUP_ID)(:-[0-9]+)?\})' \
      "${logical_lines}"; then
    fail "${script#${REPO_ROOT}/} uses a numeric ownership variable without the coreutils + prefix"
  fi
}

while IFS= read -r host_script; do
  scan_script "${host_script}"
done < <(
  {
    find "${TEST_ROOT}/debian" \
      -maxdepth 1 -type f -print
    find "${REPO_ROOT}/build/scripts" \
      -maxdepth 1 -type f -name '*.sh' -print
  } | LC_ALL=C sort
)

python3 "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py" \
  "${REPO_ROOT}/packaging" "${TEST_ROOT}/sysusers" --component sysusers
source "${REPO_ROOT}/build/scripts/release-project.sh"
release_project_load "${REPO_ROOT}/build/scripts" "$(id -u)"
export TEST_RUNTIME_UID="$RELEASE_PROJECT_UID" TEST_RUNTIME_GID="$RELEASE_PROJECT_GID"
FAKE_BIN="${TEST_ROOT}/bin"
COMMAND_LOG="${TEST_ROOT}/commands.log"
mkdir -p "${FAKE_BIN}"
: > "${COMMAND_LOG}"
for command_name in install chown chmod; do
  cat > "${FAKE_BIN}/${command_name}" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

command_name="$(basename -- "$0")"
printf '%s\t%s\n' "${command_name}" "$*" >> "${NUMERIC_OWNERSHIP_COMMAND_LOG:?}"
case "${command_name}" in
  install)
    for argument in "$@"; do
      case "${argument}" in
        -o|-g|--owner|--owner=*|--group|--group=*)
          exit 91
          ;;
      esac
    done
    ;;
  chown)
    [[ "${1:-}" == "+${TEST_RUNTIME_UID}:+${TEST_RUNTIME_GID}" ]] || exit 92
    ;;
esac
STUB
  chmod 0755 "${FAKE_BIN}/${command_name}"
done

for helper_source in \
  "${TEST_ROOT}/debian/postinst" \
  "${REPO_ROOT}/build/scripts/myscoutee-update-worker.sh" \
  "${REPO_ROOT}/build/scripts/myscoutee-tls-worker.sh"; do
  helper_file="${TEST_ROOT}/$(basename -- "${helper_source}").helper"
  sed -n \
    '/^install_numeric_owned_directory() {$/,/^}$/p' \
    "${helper_source}" > "${helper_file}"
  grep -Fq 'install_numeric_owned_directory() {' "${helper_file}" \
    || fail "numeric directory helper is missing from ${helper_source#${REPO_ROOT}/}"
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  NUMERIC_OWNERSHIP_COMMAND_LOG="${COMMAND_LOG}" \
  NUMERIC_OWNERSHIP_HELPER="${helper_file}" \
    bash -c '
      source "${NUMERIC_OWNERSHIP_HELPER}"
      install_numeric_owned_directory \
        0700 "$TEST_RUNTIME_UID" "$TEST_RUNTIME_GID" /tmp/myscoutee-numeric-owner-fixture
    '
done

[[ "$(grep -Fxc $'install\t-d -m 0700 -- /tmp/myscoutee-numeric-owner-fixture' "${COMMAND_LOG}")" == "3" ]] \
  || fail "numeric directory helpers did not separate creation from ownership"
[[ "$(grep -Fxc $'chown\t'"+${TEST_RUNTIME_UID}:+${TEST_RUNTIME_GID} -- /tmp/myscoutee-numeric-owner-fixture" "${COMMAND_LOG}")" == "3" ]] \
  || fail "numeric directory helpers did not force explicit numeric chown"
[[ "$(grep -Fxc $'chmod\t0700 -- /tmp/myscoutee-numeric-owner-fixture' "${COMMAND_LOG}")" == "3" ]] \
  || fail "numeric directory helpers did not restore the requested mode"

# Exercise the packaged system identity without changing the host's accounts.
IDENTITY_ROOT="${TEST_ROOT}/identity-root"
mkdir -p "${IDENTITY_ROOT}/etc"
printf 'root:x:0:0:root:/root:/bin/sh\n' > "${IDENTITY_ROOT}/etc/passwd"
printf 'root:x:0:\n' > "${IDENTITY_ROOT}/etc/group"
: > "${IDENTITY_ROOT}/etc/shadow"
: > "${IDENTITY_ROOT}/etc/gshadow"
# A second package's existing account must survive installation and replay.
printf 'retained-runtime:x:10003:10003:Retained:/nonexistent:/usr/sbin/nologin\n' >> "${IDENTITY_ROOT}/etc/passwd"
printf 'retained-runtime:x:10003:\n' >> "${IDENTITY_ROOT}/etc/group"
if [[ "$RELEASE_PROJECT_NAME" != myscoutee ]]; then
  printf 'myscoutee-runtime:x:10001:10001:MyScoutee runtime:/nonexistent:/usr/sbin/nologin\n' >> "${IDENTITY_ROOT}/etc/passwd"
  printf 'myscoutee-runtime:x:10001:\n' >> "${IDENTITY_ROOT}/etc/group"
fi
cp "${IDENTITY_ROOT}/etc/passwd" "${TEST_ROOT}/before-passwd"
systemd-sysusers --root="${IDENTITY_ROOT}" "${TEST_ROOT}/sysusers/${RELEASE_PROJECT_NAME}.conf"
grep -Fq "${RELEASE_PROJECT_NAME}-runtime:x:${TEST_RUNTIME_UID}:${TEST_RUNTIME_GID}:" "${IDENTITY_ROOT}/etc/passwd" \
  || fail "the runtime reader account does not match the container UID/GID"
grep -Fxq "${RELEASE_PROJECT_NAME}-runtime:x:${TEST_RUNTIME_GID}:" "${IDENTITY_ROOT}/etc/group" \
  || fail "the runtime reader group does not match the container GID"
while IFS= read -r retained; do
  grep -Fxq "$retained" "${IDENTITY_ROOT}/etc/passwd" || fail "another account changed"
done < "${TEST_ROOT}/before-passwd"
cp "${IDENTITY_ROOT}/etc/passwd" "${TEST_ROOT}/retained-passwd"
systemd-sysusers --root="${IDENTITY_ROOT}" "${TEST_ROOT}/sysusers/${RELEASE_PROJECT_NAME}.conf"
cmp "${TEST_ROOT}/retained-passwd" "${IDENTITY_ROOT}/etc/passwd" \
  || fail "reconfiguration changed the runtime identity"

# Run the actual installer collision guard with an isolated account lookup.
sed -n '/^for entry in "passwd:/,/^done$/p' "${TEST_ROOT}/debian/postinst" > "${TEST_ROOT}/guard.sh"
[[ -s "${TEST_ROOT}/guard.sh" ]] || fail "missing pre-allocation guard"
cat > "${FAKE_BIN}/getent" <<'STUB'
#!/bin/sh
printf '%s:x:%s:fixture\n' "$TEST_ACCOUNT_NAME" "$2"
STUB
chmod 0755 "${FAKE_BIN}/getent"
export MYSCOUTEE_API_UID="$TEST_RUNTIME_UID" MYSCOUTEE_API_GID="$TEST_RUNTIME_GID" PACKAGE_NAME="$RELEASE_PROJECT_NAME"
PATH="${FAKE_BIN}:$PATH" TEST_ACCOUNT_NAME="${RELEASE_PROJECT_NAME}-runtime" bash "${TEST_ROOT}/guard.sh"
if PATH="${FAKE_BIN}:$PATH" TEST_ACCOUNT_NAME=foreign-runtime bash "${TEST_ROOT}/guard.sh" 2>"${TEST_ROOT}/rejection"; then
  fail "installer accepted a foreign account before sysusers"
fi
grep -Fq 'reserved by another account' "${TEST_ROOT}/rejection" || fail "wrong collision failure"
echo "Numeric ownership policy tests passed: helpers, retained accounts, repeat install and foreign-ID rejection."
