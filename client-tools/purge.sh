#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
TRANSPORT_SCRIPT="${SCRIPT_DIR}/remote-transport.sh"

fail() {
  echo "fail $1" >&2
  exit 1
}

source "${SCRIPT_DIR}/client-project.sh"
client_project_setup "$SCRIPT_DIR" || fail "select a project with the packaging CLI"
POLICY_DIRECTORY="$CLIENT_PROJECT_POLICY_DIRECTORY"
CONFIG_FILE="${CONFIG_FILE:-${CLIENT_PROJECT_CONFIG_DIRECTORY}/install.env}"
release_project_load "${POLICY_DIRECTORY}" "$(id -u)" || fail "invalid client project policy"

[ -f "$CONFIG_FILE" ] || fail "config file not found: $CONFIG_FILE"
[ -f "$TRANSPORT_SCRIPT" ] || fail "transport helper not found: $TRANSPORT_SCRIPT"

# shellcheck source=/dev/null
. "$CONFIG_FILE"
# shellcheck source=/dev/null
. "$TRANSPORT_SCRIPT"

REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-}"
REMOTE_DEB_PATH="${REMOTE_DEB_PATH:-/tmp/${RELEASE_PROJECT_NAME}.deb}"
printf '%s\n' "$REMOTE_DEB_PATH" \
  | grep -Eq '^/tmp/[A-Za-z0-9][A-Za-z0-9._-]*\.deb$' \
  || fail "REMOTE_DEB_PATH must be a simple absolute .deb path directly under /tmp"

remote_transport_setup "$CONFIG_FILE"
trap remote_transport_cleanup EXIT

echo "Target: ${REMOTE_TRANSPORT_TARGET}"
echo "Config: ${CONFIG_FILE}"
echo "Purging the ${RELEASE_PROJECT_NAME} package on the remote host..."
remote_transport_run_root \
  env DEBIAN_FRONTEND=noninteractive \
  apt-get purge -y "$RELEASE_PROJECT_NAME"
remote_transport_run_root rm -f -- "$REMOTE_DEB_PATH"

if remote_transport_run sh -c \
    "dpkg-query -W -f='\${db:Status-Abbrev}' '${RELEASE_PROJECT_NAME}' 2>/dev/null | grep -q '^ii'"; then
  fail "${RELEASE_PROJECT_NAME} is still installed after apt-get purge"
fi

echo "Remote package purge passed."
