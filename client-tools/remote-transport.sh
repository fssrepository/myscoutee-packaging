#!/bin/sh

# Shared client-side SSH/SCP transport for the release-packaged Operator helpers.
# Callers must set REMOTE_HOST and REMOTE_USER before remote_transport_setup.

REMOTE_TRANSPORT_AUTH_MODE=""
REMOTE_TRANSPORT_ASKPASS_HELPER=""
REMOTE_TRANSPORT_PASSWORD_FILE=""

remote_transport_fail() {
  echo "fail $1" >&2
  exit 1
}

remote_transport_shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

remote_transport_quote_command() {
  result=""
  for argument in "$@"; do
    quoted_argument="$(remote_transport_shell_quote "$argument")"
    if [ -z "$result" ]; then
      result="$quoted_argument"
    else
      result="${result} ${quoted_argument}"
    fi
  done
  printf '%s' "$result"
}

remote_transport_cleanup() {
  if [ -n "$REMOTE_TRANSPORT_ASKPASS_HELPER" ]; then
    rm -f -- "$REMOTE_TRANSPORT_ASKPASS_HELPER"
  fi
  if [ -n "$REMOTE_TRANSPORT_PASSWORD_FILE" ]; then
    rm -f -- "$REMOTE_TRANSPORT_PASSWORD_FILE"
  fi
}

remote_transport_check_config_permissions() {
  config_file="$1"
  if [ -z "${REMOTE_PASSWORD:-}" ] && [ -z "${REMOTE_SUDO_PASSWORD:-}" ]; then
    return 0
  fi
  command -v stat >/dev/null 2>&1 \
    || remote_transport_fail "stat is required to validate ${config_file}"
  config_mode="$(stat -c '%a' "$config_file" 2>/dev/null || true)"
  case "$config_mode" in
    600|400)
      ;;
    *)
      remote_transport_fail \
        "${config_file} contains a password and must have mode 0600 or 0400 (current: ${config_mode:-unknown})"
      ;;
  esac
}

remote_transport_setup() {
  config_file="$1"

  [ -n "${REMOTE_HOST:-}" ] \
    || remote_transport_fail "REMOTE_HOST is required in ${config_file}"
  [ -n "${REMOTE_USER:-}" ] \
    || remote_transport_fail "REMOTE_USER is required in ${config_file}"
  remote_transport_check_config_permissions "$config_file"

  REMOTE_PORT="${REMOTE_PORT:-22}"
  REMOTE_KEY_FILE="${REMOTE_KEY_FILE:-}"
  REMOTE_PASSWORD="${REMOTE_PASSWORD:-}"
  REMOTE_SUDO_PASSWORD="${REMOTE_SUDO_PASSWORD:-${REMOTE_PASSWORD}}"
  REMOTE_HOST_KEY_CHECKING="${REMOTE_HOST_KEY_CHECKING:-accept-new}"
  REMOTE_CONNECT_TIMEOUT_SECONDS="${REMOTE_CONNECT_TIMEOUT_SECONDS:-20}"
  REMOTE_SSH_OPTIONS="${REMOTE_SSH_OPTIONS:-}"
  REMOTE_TRANSPORT_TARGET="${REMOTE_USER}@${REMOTE_HOST}"

  case "$REMOTE_PORT" in
    ""|*[!0-9]*)
      remote_transport_fail "REMOTE_PORT must be numeric"
      ;;
  esac
  case "$REMOTE_CONNECT_TIMEOUT_SECONDS" in
    ""|*[!0-9]*)
      remote_transport_fail "REMOTE_CONNECT_TIMEOUT_SECONDS must be numeric"
      ;;
  esac
  if [ -n "$REMOTE_KEY_FILE" ] && [ ! -f "$REMOTE_KEY_FILE" ]; then
    remote_transport_fail "SSH key file not found: ${REMOTE_KEY_FILE}"
  fi

  if [ -z "$REMOTE_PASSWORD" ]; then
    REMOTE_TRANSPORT_AUTH_MODE="none"
    return 0
  fi

  if command -v sshpass >/dev/null 2>&1; then
    REMOTE_TRANSPORT_AUTH_MODE="sshpass-fd"
    return 0
  fi

  command -v setsid >/dev/null 2>&1 \
    || remote_transport_fail \
      "REMOTE_PASSWORD is set, but neither sshpass nor setsid is available locally"

  REMOTE_TRANSPORT_PASSWORD_FILE="$(mktemp)"
  REMOTE_TRANSPORT_ASKPASS_HELPER="$(mktemp)"
  chmod 0600 "$REMOTE_TRANSPORT_PASSWORD_FILE"
  chmod 0700 "$REMOTE_TRANSPORT_ASKPASS_HELPER"
  printf '%s\n' "$REMOTE_PASSWORD" > "$REMOTE_TRANSPORT_PASSWORD_FILE"
  printf '%s\n' \
    '#!/bin/sh' \
    'exec /bin/cat -- "${MYSCOUTEE_ASKPASS_PASSWORD_FILE:?}"' \
    > "$REMOTE_TRANSPORT_ASKPASS_HELPER"
  REMOTE_TRANSPORT_AUTH_MODE="askpass-file"
}

remote_transport_with_auth() {
  case "$REMOTE_TRANSPORT_AUTH_MODE" in
    sshpass-fd)
      sshpass -d 9 "$@" 9<<EOF
${REMOTE_PASSWORD}
EOF
      ;;
    askpass-file)
      MYSCOUTEE_ASKPASS_PASSWORD_FILE="$REMOTE_TRANSPORT_PASSWORD_FILE" \
      SSH_ASKPASS="$REMOTE_TRANSPORT_ASKPASS_HELPER" \
      SSH_ASKPASS_REQUIRE=force \
      DISPLAY="${DISPLAY:-:0}" \
        setsid -w "$@"
      ;;
    *)
      "$@"
      ;;
  esac
}

remote_transport_ssh_raw() {
  if [ -n "$REMOTE_KEY_FILE" ]; then
    # REMOTE_SSH_OPTIONS is trusted local configuration and intentionally split.
    # shellcheck disable=SC2086
    remote_transport_with_auth ssh \
      -p "$REMOTE_PORT" \
      -o "ConnectTimeout=${REMOTE_CONNECT_TIMEOUT_SECONDS}" \
      -o "StrictHostKeyChecking=${REMOTE_HOST_KEY_CHECKING}" \
      -i "$REMOTE_KEY_FILE" \
      $REMOTE_SSH_OPTIONS \
      "$REMOTE_TRANSPORT_TARGET" \
      "$@"
    return
  fi

  # REMOTE_SSH_OPTIONS is trusted local configuration and intentionally split.
  # shellcheck disable=SC2086
  remote_transport_with_auth ssh \
    -p "$REMOTE_PORT" \
    -o "ConnectTimeout=${REMOTE_CONNECT_TIMEOUT_SECONDS}" \
    -o "StrictHostKeyChecking=${REMOTE_HOST_KEY_CHECKING}" \
    $REMOTE_SSH_OPTIONS \
    "$REMOTE_TRANSPORT_TARGET" \
    "$@"
}

remote_transport_run() {
  remote_command="$(remote_transport_quote_command "$@")"
  remote_transport_ssh_raw "$remote_command"
}

remote_transport_run_root() {
  root_command="$(remote_transport_quote_command "$@")"
  if [ -n "$REMOTE_SUDO_PASSWORD" ]; then
    remote_command="if [ \"\$(id -u)\" -eq 0 ]; then exec ${root_command}; else exec sudo -S -p '' -- ${root_command}; fi"
    printf '%s\n' "$REMOTE_SUDO_PASSWORD" \
      | remote_transport_ssh_raw "$remote_command"
    return
  fi

  remote_command="if [ \"\$(id -u)\" -eq 0 ]; then exec ${root_command}; else exec sudo -n -p '' -- ${root_command}; fi"
  remote_transport_ssh_raw "$remote_command"
}

remote_transport_scp() {
  source_path="$1"
  destination_path="$2"

  if [ -n "$REMOTE_KEY_FILE" ]; then
    # REMOTE_SSH_OPTIONS is trusted local configuration and intentionally split.
    # shellcheck disable=SC2086
    remote_transport_with_auth scp \
      -P "$REMOTE_PORT" \
      -o "ConnectTimeout=${REMOTE_CONNECT_TIMEOUT_SECONDS}" \
      -o "StrictHostKeyChecking=${REMOTE_HOST_KEY_CHECKING}" \
      -i "$REMOTE_KEY_FILE" \
      $REMOTE_SSH_OPTIONS \
      "$source_path" \
      "${REMOTE_TRANSPORT_TARGET}:${destination_path}"
    return
  fi

  # REMOTE_SSH_OPTIONS is trusted local configuration and intentionally split.
  # shellcheck disable=SC2086
  remote_transport_with_auth scp \
    -P "$REMOTE_PORT" \
    -o "ConnectTimeout=${REMOTE_CONNECT_TIMEOUT_SECONDS}" \
    -o "StrictHostKeyChecking=${REMOTE_HOST_KEY_CHECKING}" \
    $REMOTE_SSH_OPTIONS \
    "$source_path" \
    "${REMOTE_TRANSPORT_TARGET}:${destination_path}"
}
