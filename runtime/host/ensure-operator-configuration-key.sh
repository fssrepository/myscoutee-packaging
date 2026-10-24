#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/release-project.sh"
release_project_load "${SCRIPT_DIR}" "$(stat -c %u "${BASH_SOURCE[0]}")" || {
  echo 'The package-owned release project policy is missing or unsafe.' >&2; exit 1;
}

KEY_DIR="${MYSCOUTEE_OPERATOR_CONFIGURATION_KEY_DIR:-/etc/${RELEASE_PROJECT_NAME}/configuration}"
KEY_PATH="${KEY_DIR}/deployment-master-key"
OWNER_UID="${MYSCOUTEE_CONFIGURATION_OWNER_UID:-0}"
OWNER_GID="${MYSCOUTEE_CONFIGURATION_OWNER_GID:-$RELEASE_PROJECT_GID}"

validate_key() {
  local value size

  [[ -f "${KEY_PATH}" && ! -L "${KEY_PATH}" ]] || {
    echo "Operator configuration master key must be a regular non-symlink file." >&2
    return 1
  }
  [[ "$(stat -c '%h' "${KEY_PATH}")" == "1" ]] || {
    echo "Operator configuration master key must not be hard-linked." >&2
    return 1
  }
  value="$(< "${KEY_PATH}")"
  size="$(stat -c '%s' "${KEY_PATH}")"
  [[ "${value}" =~ ^[0-9a-f]{64}$ \
    && ( "${size}" == "64" || "${size}" == "65" ) ]] || {
    echo "Operator configuration master key must contain exactly 64 lowercase hexadecimal characters." >&2
    return 1
  }
}

[[ "${KEY_DIR}" == /* && "${OWNER_UID}" =~ ^[0-9]+$ \
  && "${OWNER_GID}" =~ ^[0-9]+$ ]] || {
  echo "Operator configuration key settings are invalid." >&2
  exit 1
}
[[ ! -L "${KEY_DIR}" ]] || {
  echo "Operator configuration key directory must not be a symbolic link." >&2
  exit 1
}

install -d -m 0750 -- "${KEY_DIR}"
chown "+${OWNER_UID}:+${OWNER_GID}" -- "${KEY_DIR}"
chmod 0750 -- "${KEY_DIR}"
if [[ -e "${KEY_PATH}" || -L "${KEY_PATH}" ]]; then
  validate_key
else
  temporary_key="$(mktemp "${KEY_DIR}/.deployment-master-key.XXXXXX")"
  trap 'rm -f -- "${temporary_key}"' EXIT
  openssl rand -hex 32 > "${temporary_key}"
  chmod 0640 "${temporary_key}"
  chown "+${OWNER_UID}:+${OWNER_GID}" -- "${temporary_key}"
  if ! ln "${temporary_key}" "${KEY_PATH}" 2>/dev/null; then
    validate_key
  fi
  rm -f -- "${temporary_key}"
  trap - EXIT
fi

chown "+${OWNER_UID}:+${OWNER_GID}" -- "${KEY_DIR}" "${KEY_PATH}"
chmod 0750 "${KEY_DIR}"
chmod 0640 "${KEY_PATH}"
sync -f "${KEY_PATH}"
sync -f "${KEY_DIR}"
