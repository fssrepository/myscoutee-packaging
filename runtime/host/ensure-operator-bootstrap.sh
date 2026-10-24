#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/release-project.sh"
release_project_load "${SCRIPT_DIR}" "$(stat -c %u "${BASH_SOURCE[0]}")" || {
  echo 'The package-owned release project policy is missing or unsafe.' >&2; exit 1;
}

# This helper is deliberately parameterized so its state transitions can be
# tested without executing Debian maintainer scripts against the host /etc.
ENV_FILE="${MYSCOUTEE_BOOTSTRAP_ENV_FILE:-/etc/${RELEASE_PROJECT_NAME}/${RELEASE_PROJECT_NAME}.env}"
SECRETS_FILE="${MYSCOUTEE_BOOTSTRAP_SECRETS_FILE:-/etc/${RELEASE_PROJECT_NAME}/${RELEASE_PROJECT_NAME}.secrets.env}"
OWNER_UID="${MYSCOUTEE_BOOTSTRAP_OWNER_UID:-0}"
OWNER_GID="${MYSCOUTEE_BOOTSTRAP_OWNER_GID:-0}"
OPERATOR_KEY="OPERATOR_USER"
BOOTSTRAP_EMAIL_KEY="OPERATOR_BOOTSTRAP_EMAIL"
PASSWORD_HASH_KEY="OPERATOR_BOOTSTRAP_PASSWORD_SHA256"
GENERATED_OPERATOR_PATTERN='^operator-[0-9a-f]{24}@deployment\.invalid$'
PASSWORD_HASH_PATTERN='^[0-9a-f]{64}$'

read_env_value() {
  local key="$1"
  local file="$2"
  local line value

  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  line="$(
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "${file}" \
      | tail -n 1
  )"
  value="${line%$'\r'}"
  if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "${value}"
}

require_safe_file() {
  local file="$1"
  local label="$2"

  if [[ -L "${file}" ]]; then
    echo "${label} must not be a symbolic link: ${file}" >&2
    exit 1
  fi
  if [[ -e "${file}" && ! -f "${file}" ]]; then
    echo "${label} must be a regular file: ${file}" >&2
    exit 1
  fi
  if [[ ! -f "${file}" ]]; then
    echo "${label} is missing: ${file}" >&2
    exit 1
  fi
}

random_hex() {
  local byte_count="$1"

  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "${byte_count}"
    return 0
  fi
  if [[ -r /dev/urandom ]]; then
    LC_ALL=C od -An -N"${byte_count}" -tx1 /dev/urandom | tr -d ' \n'
    return 0
  fi
  echo "Unable to generate the Operator bootstrap credential securely." >&2
  exit 1
}

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r | awk '{ print $1 }'
    return 0
  fi
  echo "Unable to hash the Operator bootstrap password." >&2
  exit 1
}

upsert_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local mode="$4"
  local parent tmp

  parent="$(dirname -- "${file}")"
  if [[ ! -d "${parent}" || -L "${parent}" ]]; then
    echo "Bootstrap configuration directory is unsafe or missing: ${parent}" >&2
    exit 1
  fi
  tmp="$(mktemp "${parent}/.$(basename -- "${file}").XXXXXX")"
  chmod "${mode}" "${tmp}"
  chown "+${OWNER_UID}:+${OWNER_GID}" -- "${tmp}"
  awk -v key="${key}" -v value="${value}" '
    BEGIN {
      replaced = 0
    }
    {
      line = $0
      candidate = line
      sub(/^[[:space:]]*/, "", candidate)
      if (candidate ~ ("^" key "[[:space:]]*=")) {
        if (!replaced) {
          print key "=" value
          replaced = 1
        }
        next
      }
      print line
    }
    END {
      if (!replaced) {
        print key "=" value
      }
    }
  ' "${file}" > "${tmp}"
  chmod "${mode}" "${tmp}"
  chown "+${OWNER_UID}:+${OWNER_GID}" -- "${tmp}"
  mv -f -- "${tmp}" "${file}"
}

if [[ ! "${OWNER_UID}" =~ ^[0-9]+$ || ! "${OWNER_GID}" =~ ^[0-9]+$ ]]; then
  echo "Operator bootstrap owner UID and GID must be numeric." >&2
  exit 1
fi

require_safe_file "${ENV_FILE}" "Operator environment file"
require_safe_file "${SECRETS_FILE}" "Operator secrets file"
chown "+${OWNER_UID}:+${OWNER_GID}" -- "${ENV_FILE}" "${SECRETS_FILE}"
chmod 0644 "${ENV_FILE}"
chmod 0600 "${SECRETS_FILE}"

operator_user="$(read_env_value "${OPERATOR_KEY}" "${ENV_FILE}" || true)"
bootstrap_email="$(read_env_value "${BOOTSTRAP_EMAIL_KEY}" "${SECRETS_FILE}" || true)"
password_hash="$(read_env_value "${PASSWORD_HASH_KEY}" "${SECRETS_FILE}" || true)"
recovering_incomplete_state=false

if [[ -n "${password_hash}" && ! "${password_hash}" =~ ${PASSWORD_HASH_PATTERN} ]]; then
  echo "${PASSWORD_HASH_KEY} must be exactly 64 lowercase hexadecimal characters." >&2
  exit 1
fi

if [[ -n "${bootstrap_email}" && ! "${bootstrap_email}" =~ ${GENERATED_OPERATOR_PATTERN} ]]; then
  echo "${BOOTSTRAP_EMAIL_KEY} is not a valid generated deployment-local identity." >&2
  exit 1
fi

if [[ -n "${password_hash}" && -z "${bootstrap_email}" ]]; then
  # A digest without its immutable subject could be rebound to another
  # OPERATOR_USER. Preserve the state and require explicit recovery.
  echo "Operator bootstrap hash exists without ${BOOTSTRAP_EMAIL_KEY}; preserving existing state without rebinding." >&2
  exit 1
fi

if [[ -n "${bootstrap_email}" && "${operator_user}" != "${bootstrap_email}" ]]; then
  # OPERATOR_USER may have been changed after bootstrap. The stored credential
  # remains bound to its original subject and is never silently rebound.
  # Java disables local bootstrap authentication through the same exact-match
  # rule, while package upgrades remain operational.
  echo "OPERATOR_USER does not exactly match ${BOOTSTRAP_EMAIL_KEY}; local bootstrap login is disabled and existing state is preserved." >&2
  exit 0
fi

if [[ -n "${bootstrap_email}" && -n "${password_hash}" ]]; then
  # Already initialized. In particular, do not print or rotate on upgrade.
  exit 0
fi

if [[ -z "${password_hash}" \
  && ( -n "${bootstrap_email}" \
    || "${operator_user}" =~ ${GENERATED_OPERATOR_PATTERN} ) ]]; then
  recovering_incomplete_state=true
fi

if [[ -z "${bootstrap_email}" \
  && -n "${operator_user}" \
  && ! "${operator_user}" =~ ${GENERATED_OPERATOR_PATTERN} ]]; then
  # A deployment owner explicitly configured a non-local Operator identity.
  # Never replace it or silently add another authentication mechanism.
  exit 0
fi

if [[ -z "${operator_user}" ]]; then
  operator_user="operator-$(random_hex 12)@deployment.invalid"
  # Publish the non-secret identity first. If installation is interrupted
  # before the subject and hash are committed, the generated-address branch
  # below can safely complete because no password has yet been printed.
  upsert_value "${ENV_FILE}" "${OPERATOR_KEY}" "${operator_user}" 0644
fi

if [[ -z "${bootstrap_email}" ]]; then
  bootstrap_email="${operator_user}"
  upsert_value "${SECRETS_FILE}" "${BOOTSTRAP_EMAIL_KEY}" "${bootstrap_email}" 0600
fi

password="$(random_hex 32)"
password_hash="$(printf '%s' "${password}" | sha256_stdin)"
if [[ ! "${password_hash}" =~ ${PASSWORD_HASH_PATTERN} ]]; then
  unset password
  echo "Generated Operator bootstrap password hash is invalid." >&2
  exit 1
fi

if [[ "${recovering_incomplete_state}" == "true" ]]; then
  echo "Incomplete Operator bootstrap state detected; issuing a replacement credential before committing its digest." >&2
fi

# Output the complete recoverable credential before committing its one-way
# digest. If stdout fails (or the process stops here), no unusable, unprinted
# password is activated; the next invocation can safely issue a replacement.
printf '%s\n' \
  'Initial deployment-local Operator credential (shown once):' \
  "  Email: ${operator_user}" \
  "  Password: ${password}" \
  '  The password remains valid for later Operator logins until you explicitly replace or disable it.' \
  '  Protect terminal, package-manager, and automation logs that may capture this output.'

upsert_value "${SECRETS_FILE}" "${PASSWORD_HASH_KEY}" "${password_hash}" 0600

unset password
