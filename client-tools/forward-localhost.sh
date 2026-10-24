#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
TRANSPORT_SCRIPT="${SCRIPT_DIR}/remote-transport.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  npm --prefix config/packaging run client -- forward-localhost [start|stop]

The helper reads its SSH target from config/packaging/client-tools/install.env, or CONFIG_FILE.
It creates same-port forwards to 127.0.0.1 on the remote deployment by default.
USAGE
}

fail() {
  echo "fail $1" >&2
  exit 1
}

LOCAL_FORWARD_PORTS_OVERRIDE_VALUE="${LOCAL_FORWARD_PORTS_OVERRIDE:-}"
CONFIG_DIRECTORY="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:-${SCRIPT_DIR}/../..}/config/packaging/client-tools"
if [ -z "${MYSCOUTEE_PACKAGING_PROJECT_ROOT:-}" ] && { [ -f "${SCRIPT_DIR}/release-project.json" ] || [ -f "${SCRIPT_DIR}/forward.json" ]; }; then CONFIG_DIRECTORY="${SCRIPT_DIR}"; fi
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIRECTORY}/install.env}"
ACTION="${1:-start}"
MIN_LOCAL_PORT=1
DEFAULT_FORWARD_PORTS=80,443
if [ -f "${CONFIG_DIRECTORY}/forward.json" ]; then
  jq -e 'type == "object" and .schemaVersion == 1
    and (.minimumLocalPort | type == "number" and floor == . and . >= 1 and . <= 65535)
    and (.allowStop | type == "boolean")
    and (.defaultPorts | type == "string" and test("^[0-9:,]+$"))' \
    "${CONFIG_DIRECTORY}/forward.json" >/dev/null || { echo 'Invalid forwarding policy.' >&2; exit 1; }
  MIN_LOCAL_PORT="$(jq -r .minimumLocalPort "${CONFIG_DIRECTORY}/forward.json")"
  DEFAULT_FORWARD_PORTS="$(jq -r .defaultPorts "${CONFIG_DIRECTORY}/forward.json")"
  if [ "$(jq -r .allowStop "${CONFIG_DIRECTORY}/forward.json")" = false ]; then ACTION=start; fi
fi
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
case "$ACTION" in start|stop) ;; *) usage; exit 2 ;; esac
[ -f "$CONFIG_FILE" ] || fail "config file not found: $CONFIG_FILE"
[ -f "$TRANSPORT_SCRIPT" ] || fail "transport helper not found: $TRANSPORT_SCRIPT"

# shellcheck source=/dev/null
. "$CONFIG_FILE"
# shellcheck source=/dev/null
. "$TRANSPORT_SCRIPT"

REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-}"
LOCAL_FORWARD_HOST="${LOCAL_FORWARD_HOST:-127.0.0.1}"
LOCAL_FORWARD_REMOTE_HOST="${LOCAL_FORWARD_REMOTE_HOST:-127.0.0.1}"
LOCAL_FORWARD_PORTS="${LOCAL_FORWARD_PORTS_OVERRIDE_VALUE:-${LOCAL_FORWARD_PORTS:-${DEFAULT_FORWARD_PORTS}}}"

[ -n "$LOCAL_FORWARD_PORTS" ] || fail "LOCAL_FORWARD_PORTS is empty"
printf '%s\n' "$LOCAL_FORWARD_HOST" \
  | grep -Eq '^(127\.0\.0\.1|::1|localhost)$' \
  || fail "LOCAL_FORWARD_HOST must remain loopback-only"
printf '%s\n' "$LOCAL_FORWARD_REMOTE_HOST" \
  | grep -Eq '^(127\.0\.0\.1|::1|localhost)$' \
  || fail "LOCAL_FORWARD_REMOTE_HOST must remain loopback-only"

validate_port() {
  port="$1"
  label="$2"

  case "$port" in
    ""|*[!0-9]*)
      fail "${label} must be numeric: ${port:-empty}"
      ;;
  esac
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    fail "${label} is outside 1..65535: $port"
  fi
}

parse_forward_spec() {
  forward_mapping="$1"

  case "$forward_mapping" in
    *:*:*)
      fail "forward mapping has more than one colon: $forward_mapping"
      ;;
    *:*)
      PARSED_LOCAL_PORT="${forward_mapping%%:*}"
      PARSED_REMOTE_PORT="${forward_mapping#*:}"
      ;;
    *)
      PARSED_LOCAL_PORT="$forward_mapping"
      PARSED_REMOTE_PORT="$forward_mapping"
      ;;
  esac
  validate_port "$PARSED_LOCAL_PORT" "local forward port"
  validate_port "$PARSED_REMOTE_PORT" "remote forward port"
  if [ "$PARSED_LOCAL_PORT" -lt "$MIN_LOCAL_PORT" ]; then
    fail "local forward ports must be non-privileged (${MIN_LOCAL_PORT}..65535): $PARSED_LOCAL_PORT"
  fi
}

start_forward() {
  local_port="$1"
  remote_port="$2"
  forward_spec="${LOCAL_FORWARD_HOST}:${local_port}:${LOCAL_FORWARD_REMOTE_HOST}:${remote_port}"

  echo "Target: $REMOTE_TRANSPORT_TARGET"
  echo "Forward: ${LOCAL_FORWARD_HOST}:${local_port}->${LOCAL_FORWARD_REMOTE_HOST}:${remote_port}"

  if [ -n "$REMOTE_KEY_FILE" ]; then
    # REMOTE_SSH_OPTIONS is trusted local configuration and intentionally split.
    # shellcheck disable=SC2086
    remote_transport_with_auth ssh \
      -p "$REMOTE_PORT" \
      -o "ConnectTimeout=${REMOTE_CONNECT_TIMEOUT_SECONDS}" \
      -o "StrictHostKeyChecking=${REMOTE_HOST_KEY_CHECKING}" \
      -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      -i "$REMOTE_KEY_FILE" \
      $REMOTE_SSH_OPTIONS \
      -fN \
      -L "$forward_spec" \
      "$REMOTE_TRANSPORT_TARGET"
    return
  fi

  # REMOTE_SSH_OPTIONS is trusted local configuration and intentionally split.
  # shellcheck disable=SC2086
  remote_transport_with_auth ssh \
    -p "$REMOTE_PORT" \
    -o "ConnectTimeout=${REMOTE_CONNECT_TIMEOUT_SECONDS}" \
    -o "StrictHostKeyChecking=${REMOTE_HOST_KEY_CHECKING}" \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    $REMOTE_SSH_OPTIONS \
    -fN \
    -L "$forward_spec" \
    "$REMOTE_TRANSPORT_TARGET"
}

matching_forward_pids() {
  local_port="$1"
  remote_port="$2"
  expected_spec="${LOCAL_FORWARD_HOST}:${local_port}:${LOCAL_FORWARD_REMOTE_HOST}:${remote_port}"

  ps -ww -eo pid=,args= | awk \
    -v self="$$" \
    -v parent="${PPID:-}" \
    -v spec="$expected_spec" \
    -v target="$REMOTE_TRANSPORT_TARGET" '
      $1 != self && $1 != parent {
        pid = $1
        $1 = ""
        args = $0
        if (args ~ /(^|[[:space:]])ssh([[:space:]]|$)/ &&
            (index(args, "-L " spec) || index(args, "-L" spec)) &&
            index(args, target)) {
          print pid
        }
      }
    '
}

replace_existing_forward() {
  local_port="$1"
  remote_port="$2"
  pids="$(matching_forward_pids "$local_port" "$remote_port")"
  [ -n "$pids" ] || return 0

  echo "Replacing existing forward on ${LOCAL_FORWARD_HOST}:${local_port} to remote port ${remote_port}"
  for pid in $pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  pids="$(matching_forward_pids "$local_port" "$remote_port")"
  [ -z "$pids" ] \
    || fail "existing forward did not stop on ${LOCAL_FORWARD_HOST}:${local_port}"
}

case "$LOCAL_FORWARD_PORTS" in
  ,*|*,|*,,*|*[!0-9,:]*)
    fail "LOCAL_FORWARD_PORTS must be comma-separated local[:remote] numeric mappings"
    ;;
esac

needs_privileged_bind=false
OLD_IFS="$IFS"
IFS=","
for spec in $LOCAL_FORWARD_PORTS; do
  parse_forward_spec "$spec"
  if [ "$PARSED_LOCAL_PORT" -lt 1024 ]; then
    needs_privileged_bind=true
  fi
done
IFS="$OLD_IFS"

if [ "$needs_privileged_bind" = true ] && [ "$(id -u)" -ne 0 ]; then
  [ -t 0 ] || fail "privileged local ports require: sudo -E $0"
  exec sudo -E "$0" "$@"
fi

remote_transport_setup "$CONFIG_FILE"
trap remote_transport_cleanup EXIT

OLD_IFS="$IFS"
IFS=","
for spec in $LOCAL_FORWARD_PORTS; do
  parse_forward_spec "$spec"
  IFS="$OLD_IFS" replace_existing_forward "$PARSED_LOCAL_PORT" "$PARSED_REMOTE_PORT"
  if [ "$ACTION" = start ]; then
    IFS="$OLD_IFS" start_forward "$PARSED_LOCAL_PORT" "$PARSED_REMOTE_PORT"
  fi
done
IFS="$OLD_IFS"

if [ "$ACTION" = start ]; then echo "Forward active"; else echo "Forward stopped"; fi
