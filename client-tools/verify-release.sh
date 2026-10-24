#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  verify-release.sh ARTIFACT RELEASE_MANIFEST RELEASE_PUBLIC_KEY TRUSTED_SPKI_SHA256

Verifies a MyScoutee Debian package or client-tools archive against the
detached Ed25519 metadata published beside a GitHub Release. The trusted
fingerprint must be obtained independently and has this exact form:

  sha256:<64 lowercase hexadecimal characters>
USAGE
}

fail() {
  echo "release verification failed: $1" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -eq 4 ]] || {
  usage
  exit 2
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# In a checkout the trusted policy has its canonical scripts owner; the signed
# client-tools archive carries the same two files next to this verifier.
if [[ -f "${SCRIPT_DIR}/release-project.sh" ]]; then
  POLICY_DIRECTORY="${SCRIPT_DIR}"
  source "${SCRIPT_DIR}/release-project.sh"
else
  POLICY_DIRECTORY="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}/config/packaging"
  source "${SCRIPT_DIR}/../release/lib/release-project.sh"
fi
release_project_load "${POLICY_DIRECTORY}" "$(id -u)" || fail "invalid client project policy"

ARTIFACT_PATH="$1"
MANIFEST_PATH="$2"
PUBLIC_KEY_PATH="$3"
TRUSTED_FINGERPRINT="$4"

for command_name in base64 dpkg-deb jq od openssl sha256sum stat tar; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "missing required command: ${command_name}"
done
for input_path in \
  "${ARTIFACT_PATH}" \
  "${MANIFEST_PATH}" \
  "${PUBLIC_KEY_PATH}"; do
  [[ -f "${input_path}" && ! -L "${input_path}" ]] \
    || fail "input must be a regular, non-symbolic-link file: ${input_path}"
done
[[ "${TRUSTED_FINGERPRINT}" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || fail "trusted public-key fingerprint is not canonical"

WORK_DIR="$(mktemp -d /tmp/myscoutee-release-verification.XXXXXX)"
cleanup() {
  rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT

PUBLIC_DER="${WORK_DIR}/release-public-key.der"
if ! openssl pkey \
    -pubin \
    -in "${PUBLIC_KEY_PATH}" \
    -outform DER \
    -out "${PUBLIC_DER}" >/dev/null 2>&1; then
  fail "release public key is not a valid public key"
fi
[[ "$(stat -c '%s' "${PUBLIC_DER}")" == "44" ]] \
  || fail "release public key is not an Ed25519 SPKI key"
PUBLIC_DER_PREFIX="$(
  od -An -tx1 -N12 "${PUBLIC_DER}" | tr -d ' \n'
)"
[[ "${PUBLIC_DER_PREFIX}" == "302a300506032b6570032100" ]] \
  || fail "release public key is not canonical Ed25519 SPKI DER"

PUBLIC_KEY_SHA256="$(sha256sum "${PUBLIC_DER}" | awk '{ print $1 }')"
ACTUAL_FINGERPRINT="sha256:${PUBLIC_KEY_SHA256}"
[[ "${ACTUAL_FINGERPRINT}" == "${TRUSTED_FINGERPRINT}" ]] \
  || fail "release public key does not match the independently trusted fingerprint"
EXPECTED_KEY_ID="pkey_${PUBLIC_KEY_SHA256:0:32}"

if ! jq -e '
    type == "object"
    and (keys | sort)
      == (["artifacts", "channel", "schemaVersion", "signingKeyId", "version"] | sort)
    and .schemaVersion == 1
    and (.version | type == "string"
      and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-qa\\.(0|[1-9][0-9]*))?$"))
    and (.channel | type == "string"
      and test("^[a-z][a-z0-9._-]{0,31}$"))
    and (.signingKeyId | type == "string"
      and test("^pkey_[0-9a-f]{32}$"))
    and (.artifacts | type == "array" and length == 2)
    and ([.artifacts[].purpose] == ["debian-package", "client-tools"])
    and all(.artifacts[];
      type == "object"
      and (keys | sort)
        == (["filename", "purpose", "sha256", "signature", "sizeBytes"] | sort)
      and (.filename | type == "string")
      and (.sizeBytes | type == "number" and . > 0 and floor == .)
      and (.sha256 | type == "string"
        and test("^sha256:[0-9a-f]{64}$"))
      and (.signature | type == "string"
        and test("^[A-Za-z0-9+/]{86}==$")))
  ' "${MANIFEST_PATH}" >/dev/null; then
  fail "release manifest schema or canonical values are invalid"
fi

RELEASE_VERSION="$(jq -r '.version' "${MANIFEST_PATH}")"
RELEASE_CHANNEL="$(jq -r '.channel' "${MANIFEST_PATH}")"
MANIFEST_KEY_ID="$(jq -r '.signingKeyId' "${MANIFEST_PATH}")"
[[ "${MANIFEST_KEY_ID}" == "${EXPECTED_KEY_ID}" ]] \
  || fail "release manifest signing key ID does not match the trusted public key"

DEBIAN_FILENAME="$(jq -r '.artifacts[0].filename' "${MANIFEST_PATH}")"
CLIENT_TOOLS_FILENAME="$(jq -r '.artifacts[1].filename' "${MANIFEST_PATH}")"
[[ "${CLIENT_TOOLS_FILENAME}" == "${RELEASE_PROJECT_NAME}-client-tools_${RELEASE_VERSION}.tar.gz" ]] \
  || fail "release manifest has a non-canonical client-tools filename"

verify_metadata_signature() {
  local artifact_index="$1"
  local message_domain="$2"
  local signature_path="${WORK_DIR}/artifact-${artifact_index}.signature"
  local message_path="${WORK_DIR}/artifact-${artifact_index}.message"
  local declared_size declared_sha declared_signature signature_round_trip

  declared_size="$(
    jq -r --argjson index "${artifact_index}" \
      '.artifacts[$index].sizeBytes' "${MANIFEST_PATH}"
  )"
  declared_sha="$(
    jq -r --argjson index "${artifact_index}" \
      '.artifacts[$index].sha256' "${MANIFEST_PATH}"
  )"
  declared_signature="$(
    jq -r --argjson index "${artifact_index}" \
      '.artifacts[$index].signature' "${MANIFEST_PATH}"
  )"

  if ! printf '%s' "${declared_signature}" \
      | base64 --decode > "${signature_path}" 2>/dev/null; then
    fail "artifact signature is not valid base64"
  fi
  [[ "$(stat -c '%s' "${signature_path}")" == "64" ]] \
    || fail "artifact signature is not an Ed25519 signature"
  signature_round_trip="$(base64 -w 0 "${signature_path}")"
  [[ "${signature_round_trip}" == "${declared_signature}" ]] \
    || fail "artifact signature is not canonical padded base64"

  printf '%s\n' \
    "${message_domain}" \
    "${RELEASE_VERSION}" \
    "${RELEASE_CHANNEL}" \
    "${declared_size}" \
    "${declared_sha}" \
    > "${message_path}"
  if ! openssl pkeyutl \
      -verify \
      -pubin \
      -inkey "${PUBLIC_KEY_PATH}" \
      -rawin \
      -in "${message_path}" \
      -sigfile "${signature_path}" >/dev/null 2>&1; then
    fail "artifact metadata signature is invalid"
  fi
}

verify_metadata_signature 0 "myscoutee-release-package-v1"
verify_metadata_signature 1 "myscoutee-release-client-tools-v1"

ARTIFACT_BASENAME="$(basename -- "${ARTIFACT_PATH}")"
case "${ARTIFACT_BASENAME}" in
  "${DEBIAN_FILENAME}")
    ARTIFACT_INDEX=0
    PACKAGE_NAME="$(dpkg-deb -f "${ARTIFACT_PATH}" Package)"
    PACKAGE_VERSION="$(dpkg-deb -f "${ARTIFACT_PATH}" Version)"
    PACKAGE_ARCHITECTURE="$(dpkg-deb -f "${ARTIFACT_PATH}" Architecture)"
    [[ "${PACKAGE_NAME}" == "${RELEASE_PROJECT_NAME}" ]] \
      || fail "Debian artifact package name is not ${RELEASE_PROJECT_NAME}"
    [[ "${PACKAGE_VERSION}" == "${RELEASE_VERSION/-/\~}" ]] \
      || fail "Debian artifact version does not match the release manifest"
    [[ "${PACKAGE_ARCHITECTURE}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] \
      || fail "Debian artifact architecture is invalid"
    [[ "${DEBIAN_FILENAME}" == \
      "${RELEASE_PROJECT_NAME}_${RELEASE_VERSION}_${PACKAGE_ARCHITECTURE}.deb" ]] \
      || fail "release manifest has a non-canonical Debian filename"
    ;;
  "${CLIENT_TOOLS_FILENAME}")
    ARTIFACT_INDEX=1
    ARCHIVE_VERSION="$(
      tar -xOzf "${ARTIFACT_PATH}" ./VERSION 2>/dev/null \
        | tr -d '\r\n'
    )"
    [[ "${ARCHIVE_VERSION}" == "${RELEASE_VERSION}" ]] \
      || fail "client-tools archive version does not match the release manifest"
    ;;
  *)
    fail "artifact filename is not declared canonically by the release manifest"
    ;;
esac

DECLARED_SIZE="$(
  jq -r --argjson index "${ARTIFACT_INDEX}" \
    '.artifacts[$index].sizeBytes' "${MANIFEST_PATH}"
)"
DECLARED_SHA="$(
  jq -r --argjson index "${ARTIFACT_INDEX}" \
    '.artifacts[$index].sha256' "${MANIFEST_PATH}"
)"
ACTUAL_SIZE="$(stat -c '%s' "${ARTIFACT_PATH}")"
ACTUAL_SHA="sha256:$(sha256sum "${ARTIFACT_PATH}" | awk '{ print $1 }')"
[[ "${ACTUAL_SIZE}" == "${DECLARED_SIZE}" ]] \
  || fail "artifact size does not match the signed release metadata"
[[ "${ACTUAL_SHA}" == "${DECLARED_SHA}" ]] \
  || fail "artifact SHA-256 does not match the signed release metadata"

printf 'Release artifact verified: %s\n' "${ARTIFACT_BASENAME}"
printf 'Release: %s (%s)\n' "${RELEASE_VERSION}" "${RELEASE_CHANNEL}"
printf 'Signing key: %s (%s)\n' "${EXPECTED_KEY_ID}" "${ACTUAL_FINGERPRINT}"
