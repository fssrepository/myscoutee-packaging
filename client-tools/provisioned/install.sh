#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd "${SCRIPT_DIR}/../.." && pwd)"
TRANSPORT_SCRIPT="${SCRIPT_DIR}/remote-transport.sh"
VERIFY_RELEASE_SCRIPT="${SCRIPT_DIR}/verify-release.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  packaging/client-tools/install.sh [path/to/@@PACKAGE_NAME@@.deb]

The local target config is gitignored:
  packaging/client-tools/install.env

Override the config path with:
  CONFIG_FILE=/path/to/install.env packaging/client-tools/install.sh [path/to/package.deb]

The wrapper uploads and installs the package. A fresh Registry starts only
when START_SERVICE=true and an explicit deployment env, TLS certificate, and
TLS private key have been validated and provisioned. External verification
remains a separate manual client command and is never run by this installer.

Published artifacts require RELEASE_MANIFEST_PATH, RELEASE_PUBLIC_KEY_PATH,
and an independently obtained RELEASE_PUBLIC_KEY_FINGERPRINT. A package built
directly from a trusted local checkout requires the explicit
ALLOW_UNSIGNED_LOCAL_PACKAGE=true development override.
USAGE
}

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

deployment_env_value() {
  deployment_key="$1"
  deployment_file="$2"
  deployment_line="$(
    sed -n \
      "s/^[[:space:]]*${deployment_key}[[:space:]]*=[[:space:]]*//p" \
      "$deployment_file" | tail -n 1
  )"
  deployment_line="${deployment_line%"$(printf '\r')"}"
  case "$deployment_line" in
    \"*\")
      deployment_line="${deployment_line#\"}"
      deployment_line="${deployment_line%\"}"
      ;;
    \'*\')
      deployment_line="${deployment_line#\'}"
      deployment_line="${deployment_line%\'}"
      ;;
  esac
  printf '%s' "$deployment_line"
}

check_private_input() {
  private_input="$1"
  private_label="$2"
  [ -f "$private_input" ] && [ ! -L "$private_input" ] \
    || fail "${private_label} must be a regular, non-symbolic-link file"
  command -v stat >/dev/null 2>&1 \
    || fail "stat is required to validate ${private_label}"
  private_mode="$(stat -c '%a' "$private_input" 2>/dev/null || true)"
  case "$private_mode" in
    600|400)
      ;;
    *)
      fail "${private_label} must have mode 0600 or 0400 (current: ${private_mode:-unknown})"
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
      -name '@@PACKAGE_NAME@@_*_*.deb' -printf '%T@ %p\n' 2>/dev/null
  done \
    | sort -nr \
    | awk 'NR == 1 { print $2 }'
}

CONFIG_DIRECTORY="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:+${MYSCOUTEE_PACKAGING_PROJECT_ROOT}/config/packaging/client-tools}"
CONFIG_DIRECTORY="${CONFIG_DIRECTORY:-${SCRIPT_DIR}}"
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
REMOTE_DEB_PATH="${REMOTE_DEB_PATH:-/tmp/@@PACKAGE_NAME@@.deb}"
RUN_APT_UPDATE="${RUN_APT_UPDATE:-false}"
QUALIFY_TIMEOUT_SECONDS="${QUALIFY_TIMEOUT_SECONDS:-300}"
ALLOW_DOWNGRADE="${ALLOW_DOWNGRADE:-false}"
START_SERVICE="${START_SERVICE:-false}"
DEPLOYMENT_ENV_FILE="${DEPLOYMENT_ENV_FILE:-}"
TLS_CERTIFICATE_FILE="${TLS_CERTIFICATE_FILE:-}"
TLS_PRIVATE_KEY_FILE="${TLS_PRIVATE_KEY_FILE:-}"
ALLOW_UNSIGNED_LOCAL_PACKAGE="${ALLOW_UNSIGNED_LOCAL_PACKAGE:-false}"
RELEASE_MANIFEST_PATH="${RELEASE_MANIFEST_PATH:-}"
RELEASE_PUBLIC_KEY_PATH="${RELEASE_PUBLIC_KEY_PATH:-}"
RELEASE_PUBLIC_KEY_FINGERPRINT="${RELEASE_PUBLIC_KEY_FINGERPRINT:-}"
VERIFY_DEPLOYMENT_URL="${VERIFY_DEPLOYMENT_URL:-}"
DEB_PATH="${DEB_PATH:-${1:-}}"
DEPLOYMENT_VERIFIER=""

if [ -f "${SCRIPT_DIR}/verify-deployment/run.mjs" ]; then
  verifier_dir="$(CDPATH= cd "${SCRIPT_DIR}/verify-deployment" && pwd)"
  DEPLOYMENT_VERIFIER="${verifier_dir}/run.mjs"
elif [ -f "${SCRIPT_DIR}/../verify-deployment/run.mjs" ]; then
  verifier_dir="$(CDPATH= cd "${SCRIPT_DIR}/../verify-deployment" && pwd)"
  DEPLOYMENT_VERIFIER="${verifier_dir}/run.mjs"
fi

if [ -z "$DEB_PATH" ]; then
  DEB_PATH="$(latest_deb)"
fi
[ -n "$DEB_PATH" ] \
  || fail "DEB_PATH is not set and no deb was found beside the helper or under packaging/dist"
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
    http://*|https://*)
      ;;
    *)
      fail "VERIFY_DEPLOYMENT_URL must use http:// or https://"
      ;;
  esac
fi

command -v dpkg-deb >/dev/null 2>&1 \
  || fail "dpkg-deb is required to inspect ${DEB_PATH}"
PACKAGE_NAME="$(dpkg-deb -f "$DEB_PATH" Package)"
PACKAGE_VERSION="$(dpkg-deb -f "$DEB_PATH" Version)"
[ "$PACKAGE_NAME" = "@@PACKAGE_NAME@@" ] \
  || fail "expected package @@PACKAGE_NAME@@, got ${PACKAGE_NAME:-missing}"
printf '%s\n' "$PACKAGE_VERSION" \
  | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
  || fail "package version must be a plain SemVer core"
dpkg --validate-version "$PACKAGE_VERSION" >/dev/null 2>&1 \
  || fail "invalid Debian package version: ${PACKAGE_VERSION}"

PROVISION_DEPLOYMENT=false
provisioning_inputs=0
for provisioning_input in \
  "$DEPLOYMENT_ENV_FILE" \
  "$TLS_CERTIFICATE_FILE" \
  "$TLS_PRIVATE_KEY_FILE"; do
  if [ -n "$provisioning_input" ]; then
    provisioning_inputs=$((provisioning_inputs + 1))
  fi
done
if [ "$provisioning_inputs" -ne 0 ]; then
  [ "$provisioning_inputs" -eq 3 ] \
    || fail "DEPLOYMENT_ENV_FILE, TLS_CERTIFICATE_FILE, and TLS_PRIVATE_KEY_FILE must be supplied together"
  PROVISION_DEPLOYMENT=true

  check_private_input "$DEPLOYMENT_ENV_FILE" "deployment env"
  [ -f "$TLS_CERTIFICATE_FILE" ] && [ ! -L "$TLS_CERTIFICATE_FILE" ] \
    || fail "TLS certificate must be a regular, non-symbolic-link file"
  check_private_input "$TLS_PRIVATE_KEY_FILE" "TLS private key"

  configured_scope="$(
    deployment_env_value REGISTRY_SCOPE "$DEPLOYMENT_ENV_FILE"
  )"
  printf '%s\n' "$configured_scope" \
    | grep -Eq '^[a-z0-9][a-z0-9._:-]{2,127}$' \
    || fail "deployment env REGISTRY_SCOPE is not canonical"
  [ "$configured_scope" != "example:region-a" ] \
    || fail "deployment env REGISTRY_SCOPE is still the example placeholder"

  configured_hostname="$(
    deployment_env_value REGISTRY_PUBLIC_HOSTNAME "$DEPLOYMENT_ENV_FILE"
  )"
  printf '%s\n' "$configured_hostname" \
    | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$' \
    || fail "deployment env REGISTRY_PUBLIC_HOSTNAME is invalid"
  case "$configured_hostname" in
    *.*)
      ;;
    *)
      fail "deployment env REGISTRY_PUBLIC_HOSTNAME must be a DNS name"
      ;;
  esac
  case "$configured_hostname" in
    *.invalid|*.invalid.)
      fail "deployment env REGISTRY_PUBLIC_HOSTNAME is still a reserved placeholder"
      ;;
  esac

  [ "$(deployment_env_value MYSCOUTEE_REGISTRY_VERSION "$DEPLOYMENT_ENV_FILE")" = \
      "$PACKAGE_VERSION" ] \
    || fail "deployment env version does not match the package"
  [ "$(deployment_env_value REGISTRY_PRODUCTION_IMAGE "$DEPLOYMENT_ENV_FILE")" = \
      "@@PACKAGE_NAME@@:${PACKAGE_VERSION}-prod" ] \
    || fail "deployment env Registry image does not match the package"
  [ "$(deployment_env_value REGISTRY_NGINX_PRODUCTION_IMAGE "$DEPLOYMENT_ENV_FILE")" = \
      "@@NGINX_IMAGE@@:${PACKAGE_VERSION}-prod" ] \
    || fail "deployment env Nginx image does not match the package"
  [ "$(deployment_env_value REGISTRY_STATE_DIR_HOST "$DEPLOYMENT_ENV_FILE")" = \
      "/var/lib/@@PACKAGE_NAME@@/data" ] \
    || fail "deployment env state directory must use the package-owned path"
  [ "$(deployment_env_value REGISTRY_TLS_CERTIFICATE_PATH "$DEPLOYMENT_ENV_FILE")" = \
      "/etc/@@PACKAGE_NAME@@/tls/fullchain.pem" ] \
    || fail "deployment env TLS certificate path must use the package-owned path"
  [ "$(deployment_env_value REGISTRY_TLS_PRIVATE_KEY_PATH "$DEPLOYMENT_ENV_FILE")" = \
      "/etc/@@PACKAGE_NAME@@/tls/privkey.pem" ] \
    || fail "deployment env TLS private-key path must use the package-owned path"

  for provisioning_command in openssl sha256sum; do
    command -v "$provisioning_command" >/dev/null 2>&1 \
      || fail "${provisioning_command} is required to validate TLS provisioning inputs"
  done
  openssl x509 -in "$TLS_CERTIFICATE_FILE" -noout >/dev/null 2>&1 \
    || fail "TLS certificate is not a valid X.509 certificate"
  openssl x509 -in "$TLS_CERTIFICATE_FILE" -checkend 0 -noout \
    >/dev/null 2>&1 \
    || fail "TLS certificate is already expired"
  openssl x509 \
    -in "$TLS_CERTIFICATE_FILE" \
    -checkhost "$configured_hostname" \
    -noout >/dev/null 2>&1 \
    || fail "TLS certificate does not cover REGISTRY_PUBLIC_HOSTNAME"
  openssl pkey -in "$TLS_PRIVATE_KEY_FILE" -passin pass: -noout \
    >/dev/null 2>&1 \
    || fail "TLS private key must be valid and usable without a passphrase"
  certificate_public_sha="$(
    openssl x509 -in "$TLS_CERTIFICATE_FILE" -pubkey -noout \
      | openssl pkey -pubin -outform DER 2>/dev/null \
      | sha256sum \
      | awk '{print $1}'
  )"
  private_public_sha="$(
    openssl pkey \
      -in "$TLS_PRIVATE_KEY_FILE" \
      -passin pass: \
      -pubout \
      -outform DER 2>/dev/null \
      | sha256sum \
      | awk '{print $1}'
  )"
  [ "$certificate_public_sha" = "$private_public_sha" ] \
    || fail "TLS certificate and private key do not match"
fi

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
REMOTE_PROVISION_DIR=""
REMOTE_PACKAGE_UPLOADED=false
cleanup() {
  if [ -n "$REMOTE_PROVISION_DIR" ]; then
    remote_transport_run rm -rf -- "$REMOTE_PROVISION_DIR" \
      >/dev/null 2>&1 || true
  fi
  if [ "$REMOTE_PACKAGE_UPLOADED" = true ]; then
    remote_transport_run rm -f -- "$REMOTE_DEB_PATH" \
      >/dev/null 2>&1 || true
  fi
  remote_transport_cleanup
}
trap cleanup EXIT

echo "Target: ${REMOTE_TRANSPORT_TARGET}"
echo "Config: ${CONFIG_FILE}"
echo "Debian package: ${DEB_PATH}"
echo "Package: ${PACKAGE_NAME} ${PACKAGE_VERSION}"
echo "Remote path: ${REMOTE_DEB_PATH}"

installed_version="$(
  remote_transport_run sh -c \
    "dpkg-query -W -f='\${Version}' @@PACKAGE_NAME@@ 2>/dev/null || true"
)"
if [ -z "$installed_version" ]; then
  echo "Remote package state: fresh install"
elif [ "$installed_version" = "$PACKAGE_VERSION" ]; then
  echo "Remote package state: same-version reinstall (${installed_version})"
else
  echo "Remote package state: ${installed_version} -> ${PACKAGE_VERSION}"
fi

service_was_active=false
if [ -n "$installed_version" ] \
    && remote_transport_run systemctl is-active --quiet \
      @@PACKAGE_NAME@@.service; then
  service_was_active=true
fi

if is_truthy "$START_SERVICE"; then
  if [ "$PROVISION_DEPLOYMENT" != true ] \
      && [ "$service_was_active" != true ]; then
    fail "START_SERVICE=true requires all three explicit provisioning inputs unless the Registry service was already active"
  fi
fi

if [ -n "$installed_version" ] \
    && dpkg --compare-versions \
      "$installed_version" gt "$PACKAGE_VERSION"; then
  if ! is_truthy "$ALLOW_DOWNGRADE"; then
    fail "refusing downgrade ${installed_version} -> ${PACKAGE_VERSION}; set ALLOW_DOWNGRADE=true explicitly"
  fi
fi

echo "Uploading Debian package..."
remote_transport_scp "$DEB_PATH" "$REMOTE_DEB_PATH"
REMOTE_PACKAGE_UPLOADED=true

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

if [ "$PROVISION_DEPLOYMENT" = true ]; then
  echo "Provisioning protected deployment configuration and TLS inputs..."
  remote_provision_candidate="$(
    remote_transport_run sh -c \
      "umask 077; mktemp -d /tmp/@@PACKAGE_NAME@@-provision.XXXXXX"
  )"
  printf '%s\n' "$remote_provision_candidate" \
    | grep -Eq '^/tmp/@@PACKAGE_NAME@@-provision\.[A-Za-z0-9]+$' \
    || fail "remote provisioning directory is unsafe"
  REMOTE_PROVISION_DIR="$remote_provision_candidate"
  remote_transport_scp \
    "$DEPLOYMENT_ENV_FILE" \
    "${REMOTE_PROVISION_DIR}/deployment.env"
  remote_transport_scp \
    "$TLS_CERTIFICATE_FILE" \
    "${REMOTE_PROVISION_DIR}/fullchain.pem"
  remote_transport_scp \
    "$TLS_PRIVATE_KEY_FILE" \
    "${REMOTE_PROVISION_DIR}/privkey.pem"
  remote_transport_run_root \
    install -d -o root -g root -m 0700 \
    /etc/@@PACKAGE_NAME@@ \
    /etc/@@PACKAGE_NAME@@/tls
  remote_transport_run_root \
    install -o root -g root -m 0644 \
    "${REMOTE_PROVISION_DIR}/fullchain.pem" \
    /etc/@@PACKAGE_NAME@@/tls/fullchain.pem
  remote_transport_run_root \
    install -o root -g root -m 0600 \
    "${REMOTE_PROVISION_DIR}/privkey.pem" \
    /etc/@@PACKAGE_NAME@@/tls/privkey.pem
  remote_transport_run_root \
    install -o root -g root -m 0600 \
    "${REMOTE_PROVISION_DIR}/deployment.env" \
    /etc/@@PACKAGE_NAME@@/registry.env
  remote_transport_run rm -rf -- "$REMOTE_PROVISION_DIR"
  REMOTE_PROVISION_DIR=""
  echo "Protected deployment inputs provisioned."
fi

if is_truthy "$START_SERVICE"; then
  echo "Running package-provided deployment qualification..."
  remote_transport_run_root \
    /opt/@@PACKAGE_NAME@@/packaging/scripts/qualify-deployment.sh \
    restart-and-check \
    --expected-version "$PACKAGE_VERSION" \
    --timeout-seconds "$QUALIFY_TIMEOUT_SECONDS"
  echo "Install and host qualification passed."
else
  echo "Package installed without starting or restarting the Registry."
  if [ "$PROVISION_DEPLOYMENT" = true ]; then
    echo "To start and qualify explicitly, run on the remote host:"
    echo "  sudo /opt/@@PACKAGE_NAME@@/packaging/scripts/qualify-deployment.sh restart-and-check --expected-version ${PACKAGE_VERSION} --timeout-seconds ${QUALIFY_TIMEOUT_SECONDS}"
  else
    echo "Before the first start, copy deployment.env.example to deployment.env,"
    echo "set the permanent scope and hostname, configure all three local input paths,"
    echo "and rerun this installer with START_SERVICE=true."
  fi
fi

if [ -n "$VERIFY_DEPLOYMENT_URL" ]; then
  echo "External deployment verification was not run automatically."
  echo "Run this separate command from the client:"
  if [ -n "$DEPLOYMENT_VERIFIER" ]; then
    echo "  node \"${DEPLOYMENT_VERIFIER}\" --url \"${VERIFY_DEPLOYMENT_URL}\" --expected-version \"${PACKAGE_VERSION}\""
  else
    echo "  deployment verifier missing; expected verify-deployment/run.mjs beside the client tools"
  fi
else
  echo "External deployment verification was not run; set VERIFY_DEPLOYMENT_URL and run verify-deployment separately."
fi
