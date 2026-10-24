#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
TRANSPORT_SCRIPT="${SCRIPT_DIR}/remote-transport.sh"
CONFIG_DIRECTORY="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:+${MYSCOUTEE_PACKAGING_PROJECT_ROOT}/config/packaging/client-tools}"
CONFIG_DIRECTORY="${CONFIG_DIRECTORY:-${SCRIPT_DIR}}"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIRECTORY}/install.env}"

fail() {
  echo "fail $1" >&2
  exit 1
}

is_truthy() {
  case "$1" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On|enabled|ENABLED|Enabled)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

[ -f "$CONFIG_FILE" ] || fail "config file not found: $CONFIG_FILE"
[ -f "$TRANSPORT_SCRIPT" ] || fail "transport helper not found: $TRANSPORT_SCRIPT"

# shellcheck source=/dev/null
. "$CONFIG_FILE"
# shellcheck source=/dev/null
. "$TRANSPORT_SCRIPT"

REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-}"
CONFIRM_PURGE_WITH_VERIFIED_BACKUP="${CONFIRM_PURGE_WITH_VERIFIED_BACKUP:-false}"

is_truthy "$CONFIRM_PURGE_WITH_VERIFIED_BACKUP" \
  || fail "purge requires CONFIRM_PURGE_WITH_VERIFIED_BACKUP=true after verifying an independent recovery-unit backup"

remote_transport_setup "$CONFIG_FILE"
trap remote_transport_cleanup EXIT

echo "Target: ${REMOTE_TRANSPORT_TARGET}"
echo "Config: ${CONFIG_FILE}"
echo "WARNING: apt package purge invokes the package lifecycle cleanup."
echo "Managed configuration, TLS material, state, keys, and managed images may be removed."
echo "The independently stored recovery-unit backup was explicitly confirmed."
echo "Invoking apt package purge for @@DISPLAY_NAME@@ on the remote host..."
remote_transport_run_root \
  env DEBIAN_FRONTEND=noninteractive \
  apt-get purge -y @@PACKAGE_NAME@@

if remote_transport_run sh -c \
    "dpkg-query -W -f='\${db:Status-Abbrev}' @@PACKAGE_NAME@@ 2>/dev/null | grep -q '^ii'"; then
  fail "@@PACKAGE_NAME@@ is still installed after apt-get purge"
fi

echo "Remote package purge passed. The wrapper issued no direct data deletion command;"
echo "package lifecycle cleanup may have removed managed data. Independent backups were not touched."
