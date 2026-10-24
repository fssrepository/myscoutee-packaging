#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/release-project.sh"
release_project_load "${SCRIPT_DIR}" "$(stat -c %u "${BASH_SOURCE[0]}")" || {
  echo 'The package-owned release project policy is missing or unsafe.' >&2; exit 1;
}
KEY_DIR="${MYSCOUTEE_REGISTRY_KEY_DIR:-$(jq -er '.hostTools.registry.keyDirectory' "$RELEASE_PROJECT_POLICY")}"
STATE_DIR="${MYSCOUTEE_REGISTRY_STATE_DIR:-$(jq -er '.hostTools.registry.stateDirectory' "$RELEASE_PROJECT_POLICY")}"
PRIVATE_KEY="${KEY_DIR}/deployment-private-key.pem"
PUBLIC_KEY="${KEY_DIR}/deployment-public-key.der"
API_UID="${MYSCOUTEE_API_UID:-$RELEASE_PROJECT_UID}"
API_GID="${MYSCOUTEE_API_GID:-$RELEASE_PROJECT_GID}"

fail() {
  echo "Deployment identity error: $1" >&2
  exit 1
}

command -v openssl >/dev/null 2>&1 || fail "openssl is required"

if [[ -L "${KEY_DIR}" || ( -e "${KEY_DIR}" && ! -d "${KEY_DIR}" ) ]]; then
  fail "key path must be a non-symlink directory: ${KEY_DIR}"
fi
if [[ -L "${STATE_DIR}" || ( -e "${STATE_DIR}" && ! -d "${STATE_DIR}" ) ]]; then
  fail "state path must be a non-symlink directory: ${STATE_DIR}"
fi
if [[ -e "${STATE_DIR}/receipts" \
  && ( -L "${STATE_DIR}/receipts" || ! -d "${STATE_DIR}/receipts" ) ]]; then
  fail "receipt path must be a non-symlink directory: ${STATE_DIR}/receipts"
fi

install -d -m 0700 "${KEY_DIR}" "${STATE_DIR}"

if [[ -L "${PRIVATE_KEY}" || -L "${PUBLIC_KEY}" ]]; then
  fail "key paths must not be symbolic links: ${KEY_DIR}"
fi
if [[ -e "${PRIVATE_KEY}" && ! -f "${PRIVATE_KEY}" ]]; then
  fail "private key is not a regular file: ${PRIVATE_KEY}"
fi
if [[ -e "${PUBLIC_KEY}" && ! -f "${PUBLIC_KEY}" ]]; then
  fail "public key is not a regular file: ${PUBLIC_KEY}"
fi

if [[ -f "${PRIVATE_KEY}" ]]; then
  if ! openssl pkey -in "${PRIVATE_KEY}" -text -noout 2>/dev/null \
    | grep -q '^ED25519 Private-Key:'; then
    fail "existing private key is not a valid Ed25519 PKCS#8 PEM key: ${PRIVATE_KEY}"
  fi

  derived_public_tmp="$(mktemp "${KEY_DIR}/.deployment-public-key.der.XXXXXX")"
  if ! openssl pkey -in "${PRIVATE_KEY}" -pubout -outform DER -out "${derived_public_tmp}"; then
    rm -f "${derived_public_tmp}"
    fail "unable to derive the public key from ${PRIVATE_KEY}"
  fi
  chmod 0644 "${derived_public_tmp}"

  if [[ -f "${PUBLIC_KEY}" ]]; then
    if ! cmp -s "${derived_public_tmp}" "${PUBLIC_KEY}"; then
      rm -f "${derived_public_tmp}"
      fail "public key does not match the preserved private key: ${PUBLIC_KEY}"
    fi
    rm -f "${derived_public_tmp}"
  else
    mv -f "${derived_public_tmp}" "${PUBLIC_KEY}"
  fi
else
  if [[ -e "${PUBLIC_KEY}" ]]; then
    fail "refusing to create a new identity while an orphaned public key exists: ${PUBLIC_KEY}"
  fi
  if find "${STATE_DIR}" -mindepth 1 -print -quit | grep -q .; then
    fail "refusing to create a new identity while preserved registry state exists under ${STATE_DIR}"
  fi

  private_tmp="$(mktemp "${KEY_DIR}/.deployment-private-key.pem.XXXXXX")"
  public_tmp="$(mktemp "${KEY_DIR}/.deployment-public-key.der.XXXXXX")"
  chmod 0600 "${private_tmp}" "${public_tmp}"

  if ! openssl genpkey -algorithm ED25519 -out "${private_tmp}"; then
    rm -f "${private_tmp}" "${public_tmp}"
    fail "unable to generate the Ed25519 private key"
  fi
  if ! openssl pkey -in "${private_tmp}" -pubout -outform DER -out "${public_tmp}"; then
    rm -f "${private_tmp}" "${public_tmp}"
    fail "unable to derive the Ed25519 public key"
  fi

  chmod 0600 "${private_tmp}"
  chmod 0644 "${public_tmp}"
  mv -f "${private_tmp}" "${PRIVATE_KEY}"
  mv -f "${public_tmp}" "${PUBLIC_KEY}"
fi

install -d -m 0700 "${STATE_DIR}/receipts"
chmod 0700 "${KEY_DIR}" "${STATE_DIR}" "${STATE_DIR}/receipts"
chmod 0600 "${PRIVATE_KEY}"
chmod 0644 "${PUBLIC_KEY}"
if [[ "${EUID}" -eq 0 ]]; then
  chown "+${API_UID}:+${API_GID}" -- \
    "${KEY_DIR}" "${STATE_DIR}" "${STATE_DIR}/receipts" \
    "${PRIVATE_KEY}" "${PUBLIC_KEY}"
fi

# Make first-install identity publication durable before the installer reports
# success. A rerun still preserves the exact same keypair.
sync -f "${PRIVATE_KEY}"
sync -f "${PUBLIC_KEY}"
sync -f "${KEY_DIR}"
sync -f "${STATE_DIR}"

fingerprint="$(openssl dgst -sha256 -r "${PUBLIC_KEY}" | awk '{ print $1 }')"
printf 'Deployment identity ready: sha256:%s\n' "${fingerprint}"
