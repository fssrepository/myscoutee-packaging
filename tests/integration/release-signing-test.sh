#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${MYSCOUTEE_PACKAGING_PROJECT:-$PWD}" && pwd -P)"
SIGNER="${SCRIPT_DIR}/../../release/signing/sign-release-artifacts.sh"
CLIENT_TOOLS="${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/client-tools"
VERIFIER="${CLIENT_TOOLS}/verify-release.sh"
export MYSCOUTEE_PACKAGING_PROJECT_ROOT="$REPO_ROOT"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/myscoutee-release-signing-test.XXXXXX")"
source "${SCRIPT_DIR}/../../release/lib/release-project.sh"
release_project_load "${REPO_ROOT}/config/packaging" "$(id -u)"
PROJECT_NAME="$RELEASE_PROJECT_NAME"
VERSION="1.2.3"
ARCHITECTURE="amd64"
CHANNEL="stable"

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  echo "release-signing-test: $*" >&2
  exit 1
}

expect_failure() {
  local label="$1"
  shift

  if "$@" > "${TEST_ROOT}/failure.stdout" 2> "${TEST_ROOT}/failure.stderr"; then
    fail "${label} unexpectedly succeeded."
  fi
}

make_deb() {
  local output_path="$1"
  local package_name="$2"
  local package_version="$3"
  local package_architecture="$4"
  local package_root

  package_root="$(mktemp -d "${TEST_ROOT}/deb-root.XXXXXX")"
  mkdir -p "${package_root}/DEBIAN" "${package_root}/opt/${PROJECT_NAME}/packaging"
  cat > "${package_root}/DEBIAN/control" <<EOF
Package: ${package_name}
Version: ${package_version}
Section: misc
Priority: optional
Architecture: ${package_architecture}
Maintainer: MyScoutee Release Test <release-test@example.invalid>
Description: Minimal release-signing fixture
EOF
  printf '%s\n' "${package_version}" \
    > "${package_root}/opt/${PROJECT_NAME}/packaging/VERSION"
  dpkg-deb --root-owner-group --build \
    "${package_root}" \
    "${output_path}" >/dev/null
}

make_client_tools() {
  local output_path="$1"
  local marker_version="$2"
  local include_secret="${3:-false}"
  local omit_transport="${4:-false}"
  local client_root

  client_root="$(mktemp -d "${TEST_ROOT}/client-root.XXXXXX")"
  mkdir -p "${client_root}/verify-deployment"
  printf '%s\n' "MyScoutee client-tools fixture" > "${client_root}/README.md"
  printf '%s\n' "${marker_version}" > "${client_root}/VERSION"
  printf '%s\n' "REMOTE_HOST=deployment.example" \
    > "${client_root}/install.env.example"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "${client_root}/install.sh"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "${client_root}/purge.sh"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "${client_root}/forward-localhost.sh"
  if [[ "${omit_transport}" != "true" ]]; then
    printf '%s\n' '#!/bin/sh' 'exit 0' > "${client_root}/remote-transport.sh"
  fi
  cp "${VERIFIER}" "${client_root}/verify-release.sh"
  install -m 0644 "${CLIENT_TOOLS}/client-project.sh" "${client_root}/client-project.sh"
  install -m 0644 "${SCRIPT_DIR}/../../release/lib/release-project.sh" "${client_root}/release-project.sh"
  install -m 0644 "$RELEASE_PROJECT_POLICY" "${client_root}/release-project.json"
  chmod 0755 "${client_root}/verify-release.sh"
  printf '%s\n' 'process.exit(0);' > "${client_root}/verify-deployment/run.mjs"
  if [[ "${include_secret}" == "true" ]]; then
    printf '%s\n' 'REMOTE_PASSWORD=must-not-ship' > "${client_root}/install.env"
  fi
  tar --sort=name -C "${client_root}" -czf "${output_path}" .
}

for command_name in dpkg-deb git jq openssl sha256sum stat tar; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "Required test command is unavailable: ${command_name}"
done
[[ -x "${SIGNER}" ]] || fail "Release signer is not executable: ${SIGNER}"
[[ -x "${VERIFIER}" ]] || fail "Release verifier is not executable: ${VERIFIER}"

release_dir="${TEST_ROOT}/release"
output_dir="${TEST_ROOT}/output"
mkdir -p "${release_dir}" "${output_dir}"
deb_path="${release_dir}/${PROJECT_NAME}_${VERSION}_${ARCHITECTURE}.deb"
client_tools_path="${release_dir}/${PROJECT_NAME}-client-tools_${VERSION}.tar.gz"
private_key="${TEST_ROOT}/release-private-key.pem"
wrong_private_key="${TEST_ROOT}/wrong-private-key.pem"
rsa_private_key="${TEST_ROOT}/rsa-private-key.pem"

make_deb "${deb_path}" "${PROJECT_NAME}" "${VERSION}" "${ARCHITECTURE}"
make_client_tools "${client_tools_path}" "${VERSION}"
openssl genpkey -algorithm Ed25519 -out "${private_key}" 2>/dev/null
openssl genpkey -algorithm Ed25519 -out "${wrong_private_key}" 2>/dev/null
openssl genpkey \
  -algorithm RSA \
  -pkeyopt rsa_keygen_bits:2048 \
  -out "${rsa_private_key}" 2>/dev/null
chmod 0600 "${private_key}" "${wrong_private_key}" "${rsa_private_key}"

"${SIGNER}" --project-root "${REPO_ROOT}" \
  --private-key "${private_key}" \
  --deb "${deb_path}" \
  --client-tools "${client_tools_path}" \
  --channel "${CHANNEL}" \
  --output-dir "${output_dir}" > "${TEST_ROOT}/signer.stdout"

manifest="${output_dir}/${PROJECT_NAME}-release_${VERSION}.json"
[[ -f "${manifest}" && ! -L "${manifest}" ]] \
  || fail "The signed release manifest was not created."
[[ "$(stat -c '%a' "${manifest}")" == "644" ]] \
  || fail "The signed release manifest has unexpected permissions."

public_key_pem="${TEST_ROOT}/release-public-key.pem"
public_key_der="${TEST_ROOT}/release-public-key.der"
wrong_public_key_pem="${TEST_ROOT}/wrong-public-key.pem"
wrong_public_key_der="${TEST_ROOT}/wrong-public-key.der"
openssl pkey \
  -in "${private_key}" \
  -passin pass: \
  -pubout \
  -out "${public_key_pem}" 2>/dev/null
openssl pkey \
  -pubin \
  -in "${public_key_pem}" \
  -outform DER \
  -out "${public_key_der}" 2>/dev/null
openssl pkey \
  -in "${wrong_private_key}" \
  -passin pass: \
  -pubout \
  -out "${wrong_public_key_pem}" 2>/dev/null
openssl pkey \
  -pubin \
  -in "${wrong_public_key_pem}" \
  -outform DER \
  -out "${wrong_public_key_der}" 2>/dev/null
expected_key_id="pkey_$(
  sha256sum "${public_key_der}" | awk '{print substr($1, 1, 32)}'
)"
expected_public_key_fingerprint="$(
  printf 'sha256:%s' "$(sha256sum "${public_key_der}" | awk '{print $1}')"
)"
expected_deb_sha256="sha256:$(sha256sum "${deb_path}" | awk '{print $1}')"
expected_client_tools_sha256="$(
  printf 'sha256:%s' "$(sha256sum "${client_tools_path}" | awk '{print $1}')"
)"
grep -Fxq \
  "Release public-key SPKI fingerprint: ${expected_public_key_fingerprint}" \
  "${TEST_ROOT}/signer.stdout" \
  || fail "The signer did not print the full public SPKI fingerprint."

"${VERIFIER}" \
  "${deb_path}" \
  "${manifest}" \
  "${public_key_pem}" \
  "${expected_public_key_fingerprint}" > "${TEST_ROOT}/verify-deb.stdout"
"${VERIFIER}" \
  "${client_tools_path}" \
  "${manifest}" \
  "${public_key_pem}" \
  "${expected_public_key_fingerprint}" > "${TEST_ROOT}/verify-client-tools.stdout"
grep -Fxq \
  "Release artifact verified: $(basename -- "${deb_path}")" \
  "${TEST_ROOT}/verify-deb.stdout" \
  || fail "The packaged verifier did not verify the signed Debian artifact."
grep -Fxq \
  "Release artifact verified: $(basename -- "${client_tools_path}")" \
  "${TEST_ROOT}/verify-client-tools.stdout" \
  || fail "The packaged verifier did not verify the signed client-tools artifact."

wrong_fingerprint="sha256:$(printf '0%.0s' {1..64})"
expect_failure "packaged verifier with wrong trusted fingerprint" \
  "${VERIFIER}" \
    "${deb_path}" \
    "${manifest}" \
    "${public_key_pem}" \
    "${wrong_fingerprint}"
wrong_public_key_fingerprint="$(
  printf 'sha256:%s' "$(sha256sum "${wrong_public_key_der}" | awk '{print $1}')"
)"
expect_failure "packaged verifier with wrong public key" \
  "${VERIFIER}" \
    "${deb_path}" \
    "${manifest}" \
    "${wrong_public_key_pem}" \
    "${wrong_public_key_fingerprint}"

jq -e \
  --arg version "${VERSION}" \
  --arg channel "${CHANNEL}" \
  --arg keyId "${expected_key_id}" \
  --arg debFilename "$(basename -- "${deb_path}")" \
  --argjson debSize "$(stat -c '%s' "${deb_path}")" \
  --arg debSha256 "${expected_deb_sha256}" \
  --arg clientFilename "$(basename -- "${client_tools_path}")" \
  --argjson clientSize "$(stat -c '%s' "${client_tools_path}")" \
  --arg clientSha256 "${expected_client_tools_sha256}" \
  '
    (keys | sort)
      == (["artifacts", "channel", "schemaVersion", "signingKeyId", "version"] | sort)
    and .schemaVersion == 1
    and .version == $version
    and .channel == $channel
    and .signingKeyId == $keyId
    and (.artifacts | length == 2)
    and ([.artifacts[].purpose] == ["debian-package", "client-tools"])
    and all(.artifacts[];
      (keys | sort)
        == (["filename", "purpose", "sha256", "signature", "sizeBytes"] | sort)
      and (.signature | test("^[A-Za-z0-9+/]{86}==$"))
    )
    and (.artifacts[0]
      | .filename == $debFilename
      and .sizeBytes == $debSize
      and .sha256 == $debSha256)
    and (.artifacts[1]
      | .filename == $clientFilename
      and .sizeBytes == $clientSize
      and .sha256 == $clientSha256)
  ' "${manifest}" >/dev/null \
  || fail "The release manifest does not satisfy the strict schema."
if grep -Fq -- "BEGIN PRIVATE KEY" "${manifest}" \
  || grep -Fq -- "$(basename -- "${private_key}")" "${manifest}"; then
  fail "Private-key data leaked into the release manifest."
fi

deb_message="${TEST_ROOT}/debian-package.message"
deb_signature="${TEST_ROOT}/debian-package.signature"
printf '%s\n' \
  "myscoutee-release-package-v1" \
  "${VERSION}" \
  "${CHANNEL}" \
  "$(stat -c '%s' "${deb_path}")" \
  "${expected_deb_sha256}" > "${deb_message}"
jq -r '.artifacts[] | select(.purpose == "debian-package") | .signature' \
  "${manifest}" \
  | openssl base64 -d -A -out "${deb_signature}"
[[ "$(stat -c '%s' "${deb_signature}")" == "64" ]] \
  || fail "The decoded Debian signature is not 64 bytes."
openssl pkeyutl \
  -verify \
  -pubin \
  -inkey "${public_key_pem}" \
  -rawin \
  -in "${deb_message}" \
  -sigfile "${deb_signature}" >/dev/null 2>&1 \
  || fail "OpenSSL could not verify the exact update-worker Debian message."

client_message="${TEST_ROOT}/client-tools.message"
client_signature="${TEST_ROOT}/client-tools.signature"
printf '%s\n' \
  "myscoutee-release-client-tools-v1" \
  "${VERSION}" \
  "${CHANNEL}" \
  "$(stat -c '%s' "${client_tools_path}")" \
  "${expected_client_tools_sha256}" > "${client_message}"
jq -r '.artifacts[] | select(.purpose == "client-tools") | .signature' \
  "${manifest}" \
  | openssl base64 -d -A -out "${client_signature}"
[[ "$(stat -c '%s' "${client_signature}")" == "64" ]] \
  || fail "The decoded client-tools signature is not 64 bytes."
openssl pkeyutl \
  -verify \
  -pubin \
  -inkey "${public_key_pem}" \
  -rawin \
  -in "${client_message}" \
  -sigfile "${client_signature}" >/dev/null 2>&1 \
  || fail "OpenSSL could not verify the exact client-tools message."

if openssl pkeyutl \
  -verify \
  -pubin \
  -inkey "${wrong_public_key_pem}" \
  -rawin \
  -in "${deb_message}" \
  -sigfile "${deb_signature}" >/dev/null 2>&1; then
  fail "The Debian signature verified with the wrong Ed25519 public key."
fi

untampered_deb="${TEST_ROOT}/untampered.deb"
cp "${deb_path}" "${untampered_deb}"
printf 'tamper' >> "${deb_path}"
tampered_message="${TEST_ROOT}/tampered-debian-package.message"
printf '%s\n' \
  "myscoutee-release-package-v1" \
  "${VERSION}" \
  "${CHANNEL}" \
  "$(stat -c '%s' "${deb_path}")" \
  "sha256:$(sha256sum "${deb_path}" | awk '{print $1}')" > "${tampered_message}"
if openssl pkeyutl \
  -verify \
  -pubin \
  -inkey "${public_key_pem}" \
  -rawin \
  -in "${tampered_message}" \
  -sigfile "${deb_signature}" >/dev/null 2>&1; then
  fail "The Debian signature verified after artifact tampering."
fi
expect_failure "packaged verifier with a tampered Debian artifact" \
  "${VERIFIER}" \
    "${deb_path}" \
    "${manifest}" \
    "${public_key_pem}" \
    "${expected_public_key_fingerprint}"
mv -f "${untampered_deb}" "${deb_path}"

manifest_before_failure="$(sha256sum "${manifest}" | awk '{print $1}')"
expect_failure "unsafe release channel" \
  "${SIGNER}" --project-root "${REPO_ROOT}" \
    --private-key "${private_key}" \
    --deb "${deb_path}" \
    --client-tools "${client_tools_path}" \
    --channel 'stable;unsafe' \
    --output-dir "${output_dir}"
[[ "$(sha256sum "${manifest}" | awk '{print $1}')" == "${manifest_before_failure}" ]] \
  || fail "A failed signing attempt replaced the valid manifest."

expect_failure "non-Ed25519 private key" \
  "${SIGNER}" --project-root "${REPO_ROOT}" \
    --private-key "${rsa_private_key}" \
    --deb "${deb_path}" \
    --client-tools "${client_tools_path}" \
    --channel "${CHANNEL}" \
    --output-dir "${output_dir}"

wrong_filename_dir="${TEST_ROOT}/wrong-deb-filename"
mkdir -p "${wrong_filename_dir}"
wrong_filename_deb="${wrong_filename_dir}/${PROJECT_NAME}_9.9.9_${ARCHITECTURE}.deb"
cp "${deb_path}" "${wrong_filename_deb}"
expect_failure "Debian filename and metadata version mismatch" \
  "${SIGNER}" --project-root "${REPO_ROOT}" \
    --private-key "${private_key}" \
    --deb "${wrong_filename_deb}" \
    --client-tools "${client_tools_path}" \
    --channel "${CHANNEL}" \
    --output-dir "${output_dir}"

wrong_package_dir="${TEST_ROOT}/wrong-package"
mkdir -p "${wrong_package_dir}"
wrong_package_deb="${wrong_package_dir}/${PROJECT_NAME}_${VERSION}_${ARCHITECTURE}.deb"
make_deb "${wrong_package_deb}" "not-myscoutee" "${VERSION}" "${ARCHITECTURE}"
expect_failure "Debian Package mismatch" \
  "${SIGNER}" --project-root "${REPO_ROOT}" \
    --private-key "${private_key}" \
    --deb "${wrong_package_deb}" \
    --client-tools "${client_tools_path}" \
    --channel "${CHANNEL}" \
    --output-dir "${output_dir}"

wrong_architecture_dir="${TEST_ROOT}/wrong-architecture"
mkdir -p "${wrong_architecture_dir}"
wrong_architecture_deb="${wrong_architecture_dir}/${PROJECT_NAME}_${VERSION}_${ARCHITECTURE}.deb"
make_deb "${wrong_architecture_deb}" "${PROJECT_NAME}" "${VERSION}" "arm64"
expect_failure "Debian Architecture and filename mismatch" \
  "${SIGNER}" --project-root "${REPO_ROOT}" \
    --private-key "${private_key}" \
    --deb "${wrong_architecture_deb}" \
    --client-tools "${client_tools_path}" \
    --channel "${CHANNEL}" \
    --output-dir "${output_dir}"

wrong_client_filename="${release_dir}/${PROJECT_NAME}-client-tools_9.9.9.tar.gz"
cp "${client_tools_path}" "${wrong_client_filename}"
expect_failure "client-tools filename mismatch" \
  "${SIGNER}" --project-root "${REPO_ROOT}" \
    --private-key "${private_key}" \
    --deb "${deb_path}" \
    --client-tools "${wrong_client_filename}" \
    --channel "${CHANNEL}" \
    --output-dir "${output_dir}"

wrong_version_dir="${TEST_ROOT}/wrong-client-version"
mkdir -p "${wrong_version_dir}"
wrong_version_archive="${wrong_version_dir}/${PROJECT_NAME}-client-tools_${VERSION}.tar.gz"
make_client_tools "${wrong_version_archive}" "9.9.9"
expect_failure "client-tools VERSION mismatch" \
  "${SIGNER}" --project-root "${REPO_ROOT}" \
    --private-key "${private_key}" \
    --deb "${deb_path}" \
    --client-tools "${wrong_version_archive}" \
    --channel "${CHANNEL}" \
    --output-dir "${output_dir}"

secret_archive_dir="${TEST_ROOT}/secret-client-tools"
mkdir -p "${secret_archive_dir}"
secret_archive="${secret_archive_dir}/${PROJECT_NAME}-client-tools_${VERSION}.tar.gz"
make_client_tools "${secret_archive}" "${VERSION}" true
expect_failure "client-tools local install.env inclusion" \
  "${SIGNER}" --project-root "${REPO_ROOT}" \
    --private-key "${private_key}" \
    --deb "${deb_path}" \
    --client-tools "${secret_archive}" \
    --channel "${CHANNEL}" \
    --output-dir "${output_dir}"

incomplete_archive_dir="${TEST_ROOT}/incomplete-client-tools"
mkdir -p "${incomplete_archive_dir}"
incomplete_archive="${incomplete_archive_dir}/${PROJECT_NAME}-client-tools_${VERSION}.tar.gz"
make_client_tools "${incomplete_archive}" "${VERSION}" false true
expect_failure "client-tools canonical member omission" \
  "${SIGNER}" --project-root "${REPO_ROOT}" \
    --private-key "${private_key}" \
    --deb "${deb_path}" \
    --client-tools "${incomplete_archive}" \
    --channel "${CHANNEL}" \
    --output-dir "${output_dir}"

git -C "${REPO_ROOT}" diff --check -- tools/README.md
for untracked_path in \
  "${SIGNER}" \
  "${SCRIPT_DIR}/release-signing-test.sh"; do
  set +e
  git -C "${REPO_ROOT}" diff \
    --no-index \
    --check \
    /dev/null \
    "${untracked_path}" > "${TEST_ROOT}/diff-check.stdout" 2>&1
  diff_check_status=$?
  set -e
  (( diff_check_status <= 1 )) \
    || fail "git diff --check rejected ${untracked_path}."
done

echo "release-signing-test: PASS"
