#!/usr/bin/env bash
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PRIVATE_KEY_PATH=""
DEB_PATH=""
CLIENT_TOOLS_PATH=""
RELEASE_CHANNEL=""
OUTPUT_DIR=""
PROJECT_ROOT=""

usage() {
  cat <<'EOF'
Usage:
  myscoutee-packaging/release/signing/sign-release-artifacts.sh \
    --project-root /trusted/project-checkout \
    --private-key /secure/release-private-key.pem \
    --deb /path/to/myscoutee_<version>_<architecture>.deb \
    --client-tools /path/to/myscoutee-client-tools_<version>.tar.gz \
    --channel stable \
    [--output-dir /path/to/release]

Creates myscoutee-release_<version>.json with detached Ed25519 signatures.
The private key must already exist as an unencrypted PKCS#8 PEM file. This
command never creates, copies, or embeds a private key.
EOF
}

fail() {
  echo "Release signing failed: $*" >&2
  exit 1
}

require_value() {
  local option="$1"
  local remaining="$2"

  (( remaining >= 2 )) || fail "${option} requires a value."
}

while (( $# > 0 )); do
  case "$1" in
    --private-key)
      require_value "$1" "$#"
      [[ -z "${PRIVATE_KEY_PATH}" ]] || fail "--private-key was provided more than once."
      PRIVATE_KEY_PATH="$2"
      shift 2
      ;;
    --project-root)
      require_value "$1" "$#"
      [[ -z "${PROJECT_ROOT}" ]] || fail "--project-root was provided more than once."
      PROJECT_ROOT="$2"
      shift 2
      ;;
    --deb)
      require_value "$1" "$#"
      [[ -z "${DEB_PATH}" ]] || fail "--deb was provided more than once."
      DEB_PATH="$2"
      shift 2
      ;;
    --client-tools)
      require_value "$1" "$#"
      [[ -z "${CLIENT_TOOLS_PATH}" ]] \
        || fail "--client-tools was provided more than once."
      CLIENT_TOOLS_PATH="$2"
      shift 2
      ;;
    --channel)
      require_value "$1" "$#"
      [[ -z "${RELEASE_CHANNEL}" ]] || fail "--channel was provided more than once."
      RELEASE_CHANNEL="$2"
      shift 2
      ;;
    --output-dir)
      require_value "$1" "$#"
      [[ -z "${OUTPUT_DIR}" ]] || fail "--output-dir was provided more than once."
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${PRIVATE_KEY_PATH}" ]] || fail "--private-key is required."
[[ -n "${PROJECT_ROOT}" ]] || fail "--project-root is required."
[[ -n "${DEB_PATH}" ]] || fail "--deb is required."
[[ -n "${CLIENT_TOOLS_PATH}" ]] || fail "--client-tools is required."
[[ -n "${RELEASE_CHANNEL}" ]] || fail "--channel is required."
[[ "${RELEASE_CHANNEL}" =~ ^[a-z][a-z0-9._-]{0,31}$ ]] \
  || fail "The channel must match [a-z][a-z0-9._-]{0,31}."

for command_name in \
  awk basename chmod dirname dpkg dpkg-deb grep head jq mktemp mv \
  openssl rm sha256sum stat tail tar; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "Required command is unavailable: ${command_name}"
done

for artifact_path in "${DEB_PATH}" "${CLIENT_TOOLS_PATH}"; do
  [[ -f "${artifact_path}" && ! -L "${artifact_path}" ]] \
    || fail "Artifact must be a regular, non-symbolic-link file: ${artifact_path}"
done
[[ -f "${PRIVATE_KEY_PATH}" && ! -L "${PRIVATE_KEY_PATH}" ]] \
  || fail "The private key must be a regular, non-symbolic-link file."

key_mode="$(stat -c '%a' "${PRIVATE_KEY_PATH}")"
if (( (8#${key_mode} & 8#077) != 0 )); then
  fail "The private key must not be readable or writable by group or other users."
fi
[[ "$(head -n 1 "${PRIVATE_KEY_PATH}")" == "-----BEGIN PRIVATE KEY-----" \
  && "$(tail -n 1 "${PRIVATE_KEY_PATH}")" == "-----END PRIVATE KEY-----" ]] \
  || fail "The private key must be an unencrypted PKCS#8 PEM file."

openssl pkey \
  -in "${PRIVATE_KEY_PATH}" \
  -passin pass: \
  -check \
  -noout >/dev/null 2>&1 \
  || fail "The PKCS#8 private key is invalid or requires a passphrase."

# Select identity from the explicit trusted project checkout, never the candidate.
source "${SCRIPT_DIR}/../lib/release-project.sh"
release_project_load "${PROJECT_ROOT}/config/packaging" "$(id -u)" \
  || fail "Invalid release project policy."

deb_package="$(dpkg-deb -f "${DEB_PATH}" Package 2>/dev/null)" \
  || fail "The Debian artifact is not a valid package."
deb_version="$(dpkg-deb -f "${DEB_PATH}" Version 2>/dev/null)" \
  || fail "The Debian artifact has no valid Version field."
deb_architecture="$(dpkg-deb -f "${DEB_PATH}" Architecture 2>/dev/null)" \
  || fail "The Debian artifact has no valid Architecture field."

[[ "${deb_package}" == "${RELEASE_PROJECT_NAME}" ]] \
  || fail "The Debian Package field must be ${RELEASE_PROJECT_NAME}."
[[ "${deb_version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(~qa\.(0|[1-9][0-9]*))?$ ]] \
  || fail "The Debian Version must be a SemVer core or <core>~qa.<number>."
dpkg --validate-version "${deb_version}" >/dev/null 2>&1 \
  || fail "The Debian Version is invalid."
release_version="${deb_version/\~/-}"
[[ "${deb_architecture}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] \
  || fail "The Debian Architecture field is invalid."

deb_filename="$(basename -- "${DEB_PATH}")"
expected_deb_filename="${RELEASE_PROJECT_NAME}_${release_version}_${deb_architecture}.deb"
[[ "${deb_filename}" == "${expected_deb_filename}" ]] \
  || fail "The Debian filename must be ${expected_deb_filename}."

client_tools_filename="$(basename -- "${CLIENT_TOOLS_PATH}")"
expected_client_tools_filename="${RELEASE_PROJECT_NAME}-client-tools_${release_version}.tar.gz"
[[ "${client_tools_filename}" == "${expected_client_tools_filename}" ]] \
  || fail "The client-tools filename must be ${expected_client_tools_filename}."

deb_size="$(stat -c '%s' "${DEB_PATH}")"
client_tools_size="$(stat -c '%s' "${CLIENT_TOOLS_PATH}")"
[[ "${deb_size}" =~ ^[1-9][0-9]*$ && "${client_tools_size}" =~ ^[1-9][0-9]*$ ]] \
  || fail "Release artifacts must not be empty."
deb_sha256="sha256:$(sha256sum "${DEB_PATH}" | awk '{print $1}')"
client_tools_sha256="sha256:$(sha256sum "${CLIENT_TOOLS_PATH}" | awk '{print $1}')"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/myscoutee-release-signing.XXXXXX")"
MANIFEST_TMP=""
cleanup() {
  if [[ -n "${MANIFEST_TMP}" ]]; then
    rm -f -- "${MANIFEST_TMP}"
  fi
  rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT

client_tools_members="${WORK_DIR}/client-tools.members"
tar -tzf "${CLIENT_TOOLS_PATH}" > "${client_tools_members}" 2>/dev/null \
  || fail "The client-tools artifact is not a valid gzip-compressed tar archive."
[[ -s "${client_tools_members}" ]] || fail "The client-tools archive is empty."
if awk '
  {
    unsafe = ($0 !~ /^\.\/.*/ || $0 ~ /(^|\/)\.\.(\/|$)/ || $0 ~ /(^|\/)install\.env($|\/)/ || index($0, "\r") != 0)
    if (unsafe) {
      exit 1
    }
  }
' "${client_tools_members}"; then
  :
else
  fail "The client-tools archive contains an unsafe or non-canonical member."
fi

for required_member in \
  "./README.md" \
  "./VERSION" \
  "./install.env.example" \
  "./install.sh" \
  "./purge.sh" \
  "./forward-localhost.sh" \
  "./remote-transport.sh" \
  "./verify-release.sh" \
  "./release-project.sh" \
  "./release-project.json" \
  "./verify-deployment/run.mjs"; do
  member_count="$(
    awk -v required="${required_member}" '$0 == required { count++ } END { print count + 0 }' \
      "${client_tools_members}"
  )"
  [[ "${member_count}" == "1" ]] \
    || fail "The client-tools archive must contain exactly one ${required_member}."
done

client_tools_version="$(tar -xOzf "${CLIENT_TOOLS_PATH}" ./VERSION 2>/dev/null)" \
  || fail "The client-tools VERSION marker could not be read."
[[ "${client_tools_version}" == "${release_version}" ]] \
  || fail "The client-tools VERSION marker must match Debian Version ${release_version}."

[[ "$(stat -c '%s' "${DEB_PATH}")" == "${deb_size}" \
  && "sha256:$(sha256sum "${DEB_PATH}" | awk '{print $1}')" == "${deb_sha256}" ]] \
  || fail "The Debian artifact changed while it was being validated."
[[ "$(stat -c '%s' "${CLIENT_TOOLS_PATH}")" == "${client_tools_size}" \
  && "sha256:$(sha256sum "${CLIENT_TOOLS_PATH}" | awk '{print $1}')" \
    == "${client_tools_sha256}" ]] \
  || fail "The client-tools artifact changed while it was being validated."

public_key_der="${WORK_DIR}/release-public-key.der"
openssl pkey \
  -in "${PRIVATE_KEY_PATH}" \
  -passin pass: \
  -pubout \
  -outform DER \
  -out "${public_key_der}" 2>/dev/null \
  || fail "The Ed25519 public key could not be derived."
public_key_description="$(
  openssl pkey \
    -pubin \
    -inform DER \
    -in "${public_key_der}" \
    -text \
    -noout 2>/dev/null
)" || fail "The derived public SPKI DER could not be parsed."
[[ "${public_key_description}" == ED25519\ Public-Key:* ]] \
  || fail "The derived public key is not Ed25519."
unset public_key_description

public_key_sha256="$(sha256sum "${public_key_der}" | awk '{print $1}')"
[[ "${public_key_sha256}" =~ ^[0-9a-f]{64}$ ]] \
  || fail "The public-key fingerprint could not be derived."
signing_key_id="pkey_${public_key_sha256:0:32}"

deb_message="${WORK_DIR}/debian-package.message"
deb_signature_file="${WORK_DIR}/debian-package.signature"
printf '%s\n' \
  "myscoutee-release-package-v1" \
  "${release_version}" \
  "${RELEASE_CHANNEL}" \
  "${deb_size}" \
  "${deb_sha256}" > "${deb_message}"
openssl pkeyutl \
  -sign \
  -inkey "${PRIVATE_KEY_PATH}" \
  -passin pass: \
  -rawin \
  -in "${deb_message}" \
  -out "${deb_signature_file}" 2>/dev/null \
  || fail "The Debian artifact could not be signed."

client_tools_message="${WORK_DIR}/client-tools.message"
client_tools_signature_file="${WORK_DIR}/client-tools.signature"
printf '%s\n' \
  "myscoutee-release-client-tools-v1" \
  "${release_version}" \
  "${RELEASE_CHANNEL}" \
  "${client_tools_size}" \
  "${client_tools_sha256}" > "${client_tools_message}"
openssl pkeyutl \
  -sign \
  -inkey "${PRIVATE_KEY_PATH}" \
  -passin pass: \
  -rawin \
  -in "${client_tools_message}" \
  -out "${client_tools_signature_file}" 2>/dev/null \
  || fail "The client-tools artifact could not be signed."

for signature_file in "${deb_signature_file}" "${client_tools_signature_file}"; do
  [[ "$(stat -c '%s' "${signature_file}")" == "64" ]] \
    || fail "OpenSSL did not produce a 64-byte Ed25519 signature."
done
openssl pkeyutl \
  -verify \
  -pubin \
  -keyform DER \
  -inkey "${public_key_der}" \
  -rawin \
  -in "${deb_message}" \
  -sigfile "${deb_signature_file}" >/dev/null 2>&1 \
  || fail "The Debian artifact signature failed self-verification."
openssl pkeyutl \
  -verify \
  -pubin \
  -keyform DER \
  -inkey "${public_key_der}" \
  -rawin \
  -in "${client_tools_message}" \
  -sigfile "${client_tools_signature_file}" >/dev/null 2>&1 \
  || fail "The client-tools artifact signature failed self-verification."

deb_signature="$(openssl base64 -A -in "${deb_signature_file}")"
client_tools_signature="$(openssl base64 -A -in "${client_tools_signature_file}")"
[[ "${deb_signature}" =~ ^[A-Za-z0-9+/]{86}==$ \
  && "${client_tools_signature}" =~ ^[A-Za-z0-9+/]{86}==$ ]] \
  || fail "OpenSSL did not produce canonical padded base64 signatures."

if [[ -z "${OUTPUT_DIR}" ]]; then
  OUTPUT_DIR="$(dirname -- "${DEB_PATH}")"
fi
[[ -d "${OUTPUT_DIR}" && ! -L "${OUTPUT_DIR}" ]] \
  || fail "The output directory must be an existing, non-symbolic-link directory."
manifest_path="${OUTPUT_DIR}/${RELEASE_PROJECT_NAME}-release_${release_version}.json"
[[ ! -L "${manifest_path}" ]] \
  || fail "The release manifest path must not be a symbolic link."
MANIFEST_TMP="$(mktemp "${OUTPUT_DIR}/.${RELEASE_PROJECT_NAME}-release_${release_version}.XXXXXX")"

jq -n \
  --arg version "${release_version}" \
  --arg channel "${RELEASE_CHANNEL}" \
  --arg signingKeyId "${signing_key_id}" \
  --arg debFilename "${deb_filename}" \
  --argjson debSizeBytes "${deb_size}" \
  --arg debSha256 "${deb_sha256}" \
  --arg debSignature "${deb_signature}" \
  --arg clientToolsFilename "${client_tools_filename}" \
  --argjson clientToolsSizeBytes "${client_tools_size}" \
  --arg clientToolsSha256 "${client_tools_sha256}" \
  --arg clientToolsSignature "${client_tools_signature}" \
  '{
    schemaVersion: 1,
    version: $version,
    channel: $channel,
    signingKeyId: $signingKeyId,
    artifacts: [
      {
        purpose: "debian-package",
        filename: $debFilename,
        sizeBytes: $debSizeBytes,
        sha256: $debSha256,
        signature: $debSignature
      },
      {
        purpose: "client-tools",
        filename: $clientToolsFilename,
        sizeBytes: $clientToolsSizeBytes,
        sha256: $clientToolsSha256,
        signature: $clientToolsSignature
      }
    ]
  }' > "${MANIFEST_TMP}"

jq -e '
  (keys | sort) == (["artifacts", "channel", "schemaVersion", "signingKeyId", "version"] | sort)
  and .schemaVersion == 1
  and (.version | test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-qa\\.(0|[1-9][0-9]*))?$"))
  and (.channel | test("^[a-z][a-z0-9._-]{0,31}$"))
  and (.signingKeyId | test("^pkey_[0-9a-f]{32}$"))
  and (.artifacts | length == 2)
  and ([.artifacts[].purpose] == ["debian-package", "client-tools"])
  and all(.artifacts[];
    (keys | sort) == (["filename", "purpose", "sha256", "signature", "sizeBytes"] | sort)
    and (.filename | type == "string")
    and (.sizeBytes | type == "number" and . > 0 and floor == .)
    and (.sha256 | test("^sha256:[0-9a-f]{64}$"))
    and (.signature | test("^[A-Za-z0-9+/]{86}==$"))
  )
' "${MANIFEST_TMP}" >/dev/null \
  || fail "The generated release manifest failed its strict schema check."

[[ "$(stat -c '%s' "${DEB_PATH}")" == "${deb_size}" \
  && "sha256:$(sha256sum "${DEB_PATH}" | awk '{print $1}')" == "${deb_sha256}" ]] \
  || fail "The Debian artifact changed before manifest publication."
[[ "$(stat -c '%s' "${CLIENT_TOOLS_PATH}")" == "${client_tools_size}" \
  && "sha256:$(sha256sum "${CLIENT_TOOLS_PATH}" | awk '{print $1}')" \
    == "${client_tools_sha256}" ]] \
  || fail "The client-tools artifact changed before manifest publication."

chmod 0644 "${MANIFEST_TMP}"
mv -f -- "${MANIFEST_TMP}" "${manifest_path}"
MANIFEST_TMP=""

echo "Signed release manifest: ${manifest_path}"
echo "Release signing key ID: ${signing_key_id}"
echo "Release public-key SPKI fingerprint: sha256:${public_key_sha256}"
