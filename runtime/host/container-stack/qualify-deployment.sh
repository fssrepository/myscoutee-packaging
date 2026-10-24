#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

fail() {
  printf 'qualify-host: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  qualify-deployment.sh check --expected-version VERSION [--timeout-seconds SECONDS]
  qualify-deployment.sh restart-and-check --expected-version VERSION [--timeout-seconds SECONDS]
USAGE
}

action="${1:-}"
case "$action" in
  check|restart-and-check)
    shift
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

expected_version=""
timeout_seconds=60
while (( $# > 0 )); do
  case "$1" in
    --expected-version)
      (( $# >= 2 )) || fail "--expected-version requires a value"
      expected_version="$2"
      shift 2
      ;;
    --timeout|--timeout-seconds)
      (( $# >= 2 )) || fail "--timeout-seconds requires a value"
      timeout_seconds="$2"
      shift 2
      ;;
    *)
      fail "unsupported argument: $1"
      ;;
  esac
done

[[ "$expected_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  fail "--expected-version must be a plain SemVer core"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] && (( timeout_seconds <= 9999 )) ||
  fail "--timeout-seconds must be an integer from 1 through 9999"

install_root="${MYSCOUTEE_REGISTRY_INSTALL_ROOT:-/opt/@@PACKAGE_NAME@@}"
env_file="${MYSCOUTEE_REGISTRY_ENV_FILE:-/etc/@@PACKAGE_NAME@@/registry.env}"
manifest="$install_root/packaging/IMAGE-MANIFEST.json"
fingerprint_helper="$install_root/packaging/scripts/image-content-fingerprint.sh"
compose_helper="$install_root/packaging/scripts/registry-compose.sh"
dpkg_query_bin="${DPKG_QUERY_BIN:-dpkg-query}"
systemctl_bin="${SYSTEMCTL_BIN:-systemctl}"
docker_bin="${DOCKER_BIN:-docker}"
curl_bin="${CURL_BIN:-curl}"
jq_bin="${JQ_BIN:-jq}"

read_env_value() {
  local key="$1"
  local line value

  [[ -f "$env_file" && ! -L "$env_file" ]] || return 1
  line="$(
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" \
      "$env_file" | tail -n 1
  )"
  [[ -n "$line" ]] || return 1
  value="${line%$'\r'}"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

for command_path in \
  "$dpkg_query_bin" "$systemctl_bin" "$docker_bin" "$curl_bin" "$jq_bin"; do
  command -v "$command_path" >/dev/null 2>&1 ||
    fail "a required host command is unavailable"
done
[[ -x "$fingerprint_helper" && ! -L "$fingerprint_helper" ]] ||
  fail "installed image fingerprint helper is missing or unsafe"
[[ -x "$compose_helper" && ! -L "$compose_helper" ]] ||
  fail "installed Compose helper is missing or unsafe"

installed_version="$(
  "$dpkg_query_bin" --show --showformat='${Version}' \
    @@PACKAGE_NAME@@ 2>/dev/null
)" || fail "@@PACKAGE_NAME@@ is not installed according to dpkg"
[[ "$installed_version" == "$expected_version" ]] ||
  fail "installed package version does not match the expected version"

"$jq_bin" -e --arg version "$expected_version" '
  .schemaVersion == 1
  and .releaseVersion == $version
  and .bundled == true
  and (.images | type == "array" and length == 2)
  and ([.images[].service] | sort == ["nginx", "registry"])
  and all(.images[];
    (.container == .service)
    and (.reference | type == "string" and length > 0)
    and (.imageId | test("^sha256:[0-9a-f]{64}$"))
    and (.contentFingerprint | test("^sha256:[0-9a-f]{64}$"))
    and (.archive | type == "string" and length > 0)
    and (.archiveSha256 | test("^sha256:[0-9a-f]{64}$")))
' "$manifest" >/dev/null 2>&1 ||
  fail "installed image manifest is missing or invalid"

configured_registry="$(read_env_value REGISTRY_PRODUCTION_IMAGE || true)"
configured_nginx="$(read_env_value REGISTRY_NGINX_PRODUCTION_IMAGE || true)"
[[ "$configured_registry" == "@@PACKAGE_NAME@@:${expected_version}-prod" ]] ||
  fail "configured Registry image does not match the package version"
[[ "$configured_nginx" == "@@NGINX_IMAGE@@:${expected_version}-prod" ]] ||
  fail "configured Nginx image does not match the package version"
expected_registry_fingerprint="$(
  "$jq_bin" -r '.images[] | select(.service == "registry") | .contentFingerprint' \
    "$manifest"
)"
expected_nginx_fingerprint="$(
  "$jq_bin" -r '.images[] | select(.service == "nginx") | .contentFingerprint' \
    "$manifest"
)"

while IFS=$'\t' read -r reference expected_fingerprint; do
  actual_fingerprint="$(
    DOCKER_BIN="$docker_bin" \
      "$fingerprint_helper" docker "$reference" 2>/dev/null || true
  )"
  [[ "$actual_fingerprint" == "$expected_fingerprint" ]] ||
    fail "installed managed image content does not match the package manifest"
done < <("$jq_bin" -r \
  '.images[] | [.reference, .contentFingerprint] | @tsv' "$manifest")

if [[ "$action" == "restart-and-check" ]]; then
  "$systemctl_bin" restart @@PACKAGE_NAME@@.service >/dev/null ||
    fail "systemd could not restart the Registry stack"
fi

public_hostname="$(read_env_value REGISTRY_PUBLIC_HOSTNAME || true)"
https_port="$(read_env_value REGISTRY_HTTPS_PORT || true)"
https_port="${https_port:-443}"
public_bind_address="$(
  read_env_value REGISTRY_PUBLIC_BIND_ADDRESS || true
)"
tls_certificate_path="$(
  read_env_value REGISTRY_TLS_CERTIFICATE_PATH || true
)"

[[ "$public_hostname" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] ||
  fail "REGISTRY_PUBLIC_HOSTNAME is invalid"
[[ "$https_port" =~ ^[0-9]+$ ]] &&
  (( https_port >= 1 && https_port <= 65535 )) ||
  fail "REGISTRY_HTTPS_PORT is invalid"
[[ "$public_bind_address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] ||
  fail "REGISTRY_PUBLIC_BIND_ADDRESS must be an explicit IPv4 address"
[[ "$tls_certificate_path" == /* ]] &&
  [[ -f "$tls_certificate_path" && ! -L "$tls_certificate_path" ]] ||
  fail "REGISTRY_TLS_CERTIFICATE_PATH is missing or unsafe"

probe_address="$public_bind_address"
if [[ "$probe_address" == "0.0.0.0" ]]; then
  probe_address="127.0.0.1"
fi
public_origin="https://${public_hostname}:${https_port}"
connect_target="${public_hostname}:${https_port}:${probe_address}:${https_port}"
health_url="${public_origin}/healthz"
identity_url="${public_origin}/v1/registry/identity"
version_url="${public_origin}/versionz"

snapshot_root="$(mktemp -d "${TMPDIR:-/tmp}/registry-qualify.XXXXXXXX")"
cleanup() {
  rm -rf -- "$snapshot_root"
}
trap cleanup EXIT
health_json="$snapshot_root/health.json"
identity_json="$snapshot_root/identity.json"
version_json="$snapshot_root/version.json"

probe() {
  local service container_id running_reference running_image_id
  local running_fingerprint expected_running_fingerprint health_status

  "$systemctl_bin" is-active --quiet @@PACKAGE_NAME@@.service \
    >/dev/null 2>&1 || return 1
  for service in registry nginx; do
    container_id="$(
      DOCKER_BIN="$docker_bin" \
        MYSCOUTEE_REGISTRY_INSTALL_ROOT="$install_root" \
        MYSCOUTEE_REGISTRY_ENV_FILE="$env_file" \
        "$compose_helper" ps --quiet "$service" 2>/dev/null
    )"
    [[ "$container_id" =~ ^[0-9a-f]{12,64}$ ]] || return 1
    running_reference="$(
      "$docker_bin" inspect --format '{{.Config.Image}}' \
        "$container_id" 2>/dev/null
    )"
    running_image_id="$(
      "$docker_bin" inspect --format '{{.Image}}' \
        "$container_id" 2>/dev/null
    )"
    health_status="$(
      "$docker_bin" inspect --format '{{.State.Health.Status}}' \
        "$container_id" 2>/dev/null
    )"
    case "$service" in
      registry)
        [[ "$running_reference" == "$configured_registry" ]] || return 1
        expected_running_fingerprint="$expected_registry_fingerprint"
        ;;
      nginx)
        [[ "$running_reference" == "$configured_nginx" ]] || return 1
        expected_running_fingerprint="$expected_nginx_fingerprint"
        ;;
    esac
    [[ "$running_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    running_fingerprint="$(
      DOCKER_BIN="$docker_bin" \
        "$fingerprint_helper" docker "$running_image_id" 2>/dev/null || true
    )"
    [[ "$running_fingerprint" == "$expected_running_fingerprint" ]] || return 1
    [[ "$health_status" == "healthy" ]] || return 1
  done

  "$curl_bin" --fail --silent --show-error \
    --noproxy '*' --proto '=https' --tlsv1.2 \
    --cacert "$tls_certificate_path" --connect-to "$connect_target" \
    --connect-timeout 2 --max-time 5 \
    --output "$health_json" "$health_url" >/dev/null 2>&1 || return 1
  "$curl_bin" --fail --silent --show-error \
    --noproxy '*' --proto '=https' --tlsv1.2 \
    --cacert "$tls_certificate_path" --connect-to "$connect_target" \
    --connect-timeout 2 --max-time 5 \
    --output "$identity_json" "$identity_url" >/dev/null 2>&1 || return 1
  "$curl_bin" --fail --silent --show-error \
    --noproxy '*' --proto '=https' --tlsv1.2 \
    --cacert "$tls_certificate_path" --connect-to "$connect_target" \
    --connect-timeout 2 --max-time 5 \
    --output "$version_json" "$version_url" >/dev/null 2>&1 || return 1
  [[ "$(wc -c <"$health_json")" -le 65536 ]] || return 1
  [[ "$(wc -c <"$identity_json")" -le 65536 ]] || return 1
  [[ "$(wc -c <"$version_json")" -le 65536 ]] || return 1
  "$jq_bin" -e '
    .status == "ok"
    and (.protocol_version | type == "string" and length > 0)
    and (.registry_scope | type == "string" and length > 0)
    and (.registry_key_id | type == "string" and length > 0)
    and (.ledger_index | type == "number")
    and (.entry_count | type == "number")
    and (.ledger_head_hash | type == "string" and length > 0)
  ' "$health_json" >/dev/null 2>&1 || return 1
  "$jq_bin" -e --slurpfile health "$health_json" '
    (.protocol_version == $health[0].protocol_version)
    and (.registry_scope == $health[0].registry_scope)
    and (.registry_key_id == $health[0].registry_key_id)
    and (.registry_public_key | type == "string" and length > 0)
    and (.signature | type == "string" and length > 0)
  ' "$identity_json" >/dev/null 2>&1 || return 1
  "$jq_bin" -e \
    --arg expectedVersion "$expected_version" \
    --slurpfile health "$health_json" \
    --slurpfile identity "$identity_json" '
      .service == "@@PACKAGE_NAME@@"
      and .version == $expectedVersion
      and .protocol_version == $health[0].protocol_version
      and .protocol_version == $identity[0].protocol_version
    ' "$version_json" >/dev/null 2>&1 || return 1
}

deadline=$((SECONDS + timeout_seconds))
while ! probe; do
  (( SECONDS < deadline )) ||
    fail "qualification timed out without exposing response or secret data"
  sleep 1
done

printf '@@DISPLAY_NAME@@ %s host qualification: PASS\n' "$expected_version"
