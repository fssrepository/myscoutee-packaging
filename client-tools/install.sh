#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:-$(CDPATH= cd "${SCRIPT_DIR}/../.." && pwd)}"
TRANSPORT_SCRIPT="${SCRIPT_DIR}/remote-transport.sh"
VERIFY_RELEASE_SCRIPT="${SCRIPT_DIR}/verify-release.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  npm --prefix config/packaging run client -- install [path/to/myscoutee.deb]

The local target config is gitignored:
  config/packaging/client-tools/install.env

Override the config path with:
  CONFIG_FILE=/path/to/install.env npm --prefix config/packaging run client -- install [path/to/myscoutee.deb]

This is a thin client wrapper. It uploads and installs the package, then calls
the qualification command shipped inside that package. Public deployment
verification remains a separate external command under verify-deployment.

GitHub Release artifacts require RELEASE_MANIFEST_PATH,
RELEASE_PUBLIC_KEY_PATH, and the independently obtained full
RELEASE_PUBLIC_KEY_FINGERPRINT. Locally built unsigned packages require the
explicit ALLOW_UNSIGNED_LOCAL_PACKAGE=true development override.
USAGE
}

fail() {
  echo "fail $1" >&2
  exit 1
}

# Same package-owned identity as the signed-artifact verifier. The client
# archive carries this policy beside the scripts; source checkouts use scripts/.
source "${SCRIPT_DIR}/client-project.sh"
client_project_setup "$SCRIPT_DIR" || fail "select a project with the packaging CLI"
POLICY_DIRECTORY="$CLIENT_PROJECT_POLICY_DIRECTORY"
release_project_load "${POLICY_DIRECTORY}" "$(id -u)" || fail "invalid client project policy"

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

latest_deb() {
  for candidate_dir in \
    "${SCRIPT_DIR}" \
    "${SCRIPT_DIR}/.." \
    "${REPO_ROOT}/build/packaging/dist"; do
    [ -d "$candidate_dir" ] || continue
    find "$candidate_dir" -maxdepth 1 -type f \
      -name "${RELEASE_PROJECT_NAME}_*_*.deb" -printf '%T@ %p\n' 2>/dev/null
  done \
    | sort -nr \
    | awk 'NR == 1 { print $2 }'
}

CONFIG_DIRECTORY="$CLIENT_PROJECT_CONFIG_DIRECTORY"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIRECTORY}/install.env}"
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
[ -f "$CONFIG_FILE" ] || fail "config file not found: $CONFIG_FILE"
[ -f "$TRANSPORT_SCRIPT" ] || fail "transport helper not found: $TRANSPORT_SCRIPT"

# shellcheck source=/dev/null
. "$CONFIG_FILE"
# shellcheck source=/dev/null
. "$TRANSPORT_SCRIPT"

REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-}"
REMOTE_DEB_PATH="${REMOTE_DEB_PATH:-/tmp/${RELEASE_PROJECT_NAME}.deb}"
RUN_APT_UPDATE="${RUN_APT_UPDATE:-false}"
START_SERVICE="${START_SERVICE:-true}"
STOP_ON_FAILURE="${STOP_ON_FAILURE:-true}"
QUALIFY_TIMEOUT_SECONDS="${QUALIFY_TIMEOUT_SECONDS:-300}"
ALLOW_DOWNGRADE="${ALLOW_DOWNGRADE:-false}"
ALLOW_UNSIGNED_LOCAL_PACKAGE="${ALLOW_UNSIGNED_LOCAL_PACKAGE:-false}"
RELEASE_MANIFEST_PATH="${RELEASE_MANIFEST_PATH:-}"
RELEASE_PUBLIC_KEY_PATH="${RELEASE_PUBLIC_KEY_PATH:-}"
RELEASE_PUBLIC_KEY_FINGERPRINT="${RELEASE_PUBLIC_KEY_FINGERPRINT:-}"
VERIFY_DEPLOYMENT_URL="${VERIFY_DEPLOYMENT_URL:-}"
DEB_PATH="${DEB_PATH:-${1:-}}"
DEPLOYMENT_VERIFIER=""

if [ -f "${SCRIPT_DIR}/verify-deployment/run.mjs" ]; then
  deployment_verifier_dir="$(
    CDPATH= cd "${SCRIPT_DIR}/verify-deployment" && pwd
  )"
  DEPLOYMENT_VERIFIER="${deployment_verifier_dir}/run.mjs"
elif [ -f "${SCRIPT_DIR}/../verify-deployment/run.mjs" ]; then
  deployment_verifier_dir="$(
    CDPATH= cd "${SCRIPT_DIR}/../verify-deployment" && pwd
  )"
  DEPLOYMENT_VERIFIER="${deployment_verifier_dir}/run.mjs"
elif [ -f "${SCRIPT_DIR}/../verification/public/run.mjs" ]; then
  DEPLOYMENT_VERIFIER="$(CDPATH= cd "${SCRIPT_DIR}/../verification/public" && pwd)/run.mjs"
fi

if [ -z "$DEB_PATH" ]; then
  DEB_PATH="$(latest_deb)"
fi
[ -n "$DEB_PATH" ] \
  || fail "DEB_PATH is not set and no deb was found beside the helper or under build/packaging/dist"
[ -f "$DEB_PATH" ] || fail "deb file not found: $DEB_PATH"
printf '%s\n' "$REMOTE_DEB_PATH" \
  | grep -Eq '^/tmp/[A-Za-z0-9][A-Za-z0-9._-]*\.deb$' \
  || fail "REMOTE_DEB_PATH must be a simple absolute .deb path directly under /tmp"
case "$QUALIFY_TIMEOUT_SECONDS" in
  ""|*[!0-9]*)
    fail "QUALIFY_TIMEOUT_SECONDS must be numeric"
    ;;
esac
if [ "$QUALIFY_TIMEOUT_SECONDS" -lt 1 ] \
    || [ "$QUALIFY_TIMEOUT_SECONDS" -gt 9999 ]; then
  fail "QUALIFY_TIMEOUT_SECONDS must be between 1 and 9999"
fi
if [ -n "$VERIFY_DEPLOYMENT_URL" ]; then
  case "$VERIFY_DEPLOYMENT_URL" in
    https://*)
      ;;
    *)
      fail "VERIFY_DEPLOYMENT_URL must use https://"
      ;;
  esac
fi

command -v dpkg-deb >/dev/null 2>&1 \
  || fail "dpkg-deb is required to inspect ${DEB_PATH}"
PACKAGE_NAME="$(dpkg-deb -f "$DEB_PATH" Package)"
PACKAGE_VERSION="$(dpkg-deb -f "$DEB_PATH" Version)"
[ "$PACKAGE_NAME" = "$RELEASE_PROJECT_NAME" ] \
  || fail "expected package ${RELEASE_PROJECT_NAME}, got ${PACKAGE_NAME:-missing}"
printf '%s\n' "$PACKAGE_VERSION" \
  | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(~qa\.[1-9][0-9]*)?$' \
  || fail "package version must be a SemVer core or QA prerelease"
dpkg --validate-version "$PACKAGE_VERSION" >/dev/null 2>&1 \
  || fail "invalid Debian package version: ${PACKAGE_VERSION}"

release_verification_configured=false
for release_value in \
  "$RELEASE_MANIFEST_PATH" \
  "$RELEASE_PUBLIC_KEY_PATH" \
  "$RELEASE_PUBLIC_KEY_FINGERPRINT"; do
  if [ -n "$release_value" ]; then
    release_verification_configured=true
  fi
done
if [ "$release_verification_configured" = true ]; then
  [ -n "$RELEASE_MANIFEST_PATH" ] \
    || fail "RELEASE_MANIFEST_PATH is required for signed release verification"
  [ -n "$RELEASE_PUBLIC_KEY_PATH" ] \
    || fail "RELEASE_PUBLIC_KEY_PATH is required for signed release verification"
  [ -n "$RELEASE_PUBLIC_KEY_FINGERPRINT" ] \
    || fail "RELEASE_PUBLIC_KEY_FINGERPRINT is required for signed release verification"
  [ -x "$VERIFY_RELEASE_SCRIPT" ] \
    || fail "release verifier is missing or not executable: $VERIFY_RELEASE_SCRIPT"
  "$VERIFY_RELEASE_SCRIPT" \
    "$DEB_PATH" \
    "$RELEASE_MANIFEST_PATH" \
    "$RELEASE_PUBLIC_KEY_PATH" \
    "$RELEASE_PUBLIC_KEY_FINGERPRINT"
elif is_truthy "$ALLOW_UNSIGNED_LOCAL_PACKAGE"; then
  echo "WARNING: using the explicit unsigned local-package development override." >&2
else
  fail "unsigned package refused; configure release verification or set ALLOW_UNSIGNED_LOCAL_PACKAGE=true only for a local build"
fi

remote_transport_setup "$CONFIG_FILE"
trap remote_transport_cleanup EXIT

echo "Target: ${REMOTE_TRANSPORT_TARGET}"
echo "Config: ${CONFIG_FILE}"
echo "Debian package: ${DEB_PATH}"
echo "Package: ${PACKAGE_NAME} ${PACKAGE_VERSION}"
echo "Remote path: ${REMOTE_DEB_PATH}"

echo "Uploading Debian package..."
remote_transport_scp "$DEB_PATH" "$REMOTE_DEB_PATH"

installed_version="$(
  remote_transport_run sh -c \
    "dpkg-query -W -f='\${Version}' '${RELEASE_PROJECT_NAME}' 2>/dev/null || true"
)"
if [ -z "$installed_version" ]; then
  echo "Remote package state: fresh install"
elif [ "$installed_version" = "$PACKAGE_VERSION" ]; then
  echo "Remote package state: same-version reinstall (${installed_version})"
else
  echo "Remote package state: ${installed_version} -> ${PACKAGE_VERSION}"
fi

if [ -n "$installed_version" ] \
    && dpkg --compare-versions \
      "$installed_version" gt "$PACKAGE_VERSION"; then
  if ! is_truthy "$ALLOW_DOWNGRADE"; then
    fail "refusing downgrade ${installed_version} -> ${PACKAGE_VERSION}; set ALLOW_DOWNGRADE=true explicitly"
  fi
fi

if is_truthy "$RUN_APT_UPDATE"; then
  echo "Refreshing remote APT metadata..."
  remote_transport_run_root apt-get update
fi

if [ "$installed_version" = "$PACKAGE_VERSION" ]; then
  echo "Refreshing same-version package payload..."
  remote_transport_run_root dpkg --unpack "$REMOTE_DEB_PATH"
  echo "Resolving dependencies and configuring package..."
  remote_transport_run_root \
    env DEBIAN_FRONTEND=noninteractive \
    apt-get -f install -y --no-remove
else
  echo "Installing package..."
  set -- env DEBIAN_FRONTEND=noninteractive apt-get install -y
  if [ -n "$installed_version" ] && is_truthy "$ALLOW_DOWNGRADE"; then
    set -- "$@" --allow-downgrades
  fi
  set -- "$@" "$REMOTE_DEB_PATH"
  remote_transport_run_root "$@"
fi

qualification_mode="check"
if is_truthy "$START_SERVICE"; then
  qualification_mode="restart-and-check"
fi
set -- \
  "${RELEASE_PROJECT_ROOT}/packaging/scripts/qualify-deployment.sh" \
  "$qualification_mode" \
  --expected-version "$PACKAGE_VERSION" \
  --timeout-seconds "$QUALIFY_TIMEOUT_SECONDS"
if ! is_truthy "$STOP_ON_FAILURE"; then
  set -- "$@" --leave-running-on-failure
fi

echo "Running package-provided deployment qualification..."
remote_transport_run_root "$@"

remote_transport_run_root "${RELEASE_PROJECT_ROOT}/packaging/scripts/record-installed-package.sh" "$REMOTE_DEB_PATH"

echo "Install and host qualification passed."
if [ -n "$VERIFY_DEPLOYMENT_URL" ]; then
  echo "Run the separate external deployment verification from this client:"
  if [ -n "$DEPLOYMENT_VERIFIER" ]; then
    if [ -n "${MYSCOUTEE_PACKAGING_PROJECT_ROOT:-}" ]; then
      echo "  npm --prefix \"${MYSCOUTEE_PACKAGING_PROJECT_ROOT}/config/packaging\" run verify -- --url ${VERIFY_DEPLOYMENT_URL} --expected-version ${PACKAGE_VERSION}"
    else
      echo "  node \"${DEPLOYMENT_VERIFIER}\" --url ${VERIFY_DEPLOYMENT_URL} --expected-version ${PACKAGE_VERSION}"
    fi
  else
    echo "  deployment verifier missing; expected verify-deployment/run.mjs beside the client tools"
  fi
else
  echo "External deployment verification was not run; set VERIFY_DEPLOYMENT_URL and invoke verify-deployment separately."
fi
