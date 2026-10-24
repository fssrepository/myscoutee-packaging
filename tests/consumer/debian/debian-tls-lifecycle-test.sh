#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:-$PWD}"
export DPKG_MAINTSCRIPT_PACKAGE="$(jq -er .packageName "$REPO_ROOT/config/packaging/release-project.json")"
TEST_ROOT="$(mktemp -d /tmp/myscoutee-debian-tls-lifecycle-test.XXXXXX)"

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT
mkdir -p "${TEST_ROOT}/debian"
python3 "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py" "${REPO_ROOT}/packaging" "${TEST_ROOT}/debian" --hook all
POSTINST="${TEST_ROOT}/debian/postinst"
PRERM="${TEST_ROOT}/debian/prerm"

fail() {
  echo "Debian TLS lifecycle test failed: $1" >&2
  exit 1
}

TLS_FUNCTION="${TEST_ROOT}/ensure-bootstrap-tls-pair.sh"
sed -n \
  '/^ensure_bootstrap_tls_pair() {$/,/^}$/p' \
  "${POSTINST}" > "${TLS_FUNCTION}"
grep -Fq 'ensure_bootstrap_tls_pair() {' "${TLS_FUNCTION}" \
  || fail "could not extract the postinst TLS bootstrap function"
# shellcheck source=/dev/null
source "${TLS_FUNCTION}"

assert_matching_pair() {
  local certificate="$1"
  local private_key="$2"
  local certificate_public_key
  local private_public_key

  certificate_public_key="$(
    openssl x509 -in "${certificate}" -pubkey -noout \
      | openssl pkey -pubin -outform DER 2>/dev/null \
      | sha256sum \
      | awk '{ print $1 }'
  )"
  private_public_key="$(
    openssl pkey -in "${private_key}" -pubout -outform DER 2>/dev/null \
      | sha256sum \
      | awk '{ print $1 }'
  )"
  [[ "${certificate_public_key}" == "${private_public_key}" ]] \
    || fail "the bootstrap certificate and private key do not match"
}

BOOTSTRAP_DIR="${TEST_ROOT}/bootstrap"
BOOTSTRAP_CERT="${BOOTSTRAP_DIR}/nginx.crt"
BOOTSTRAP_KEY="${BOOTSTRAP_DIR}/nginx-nopass.key"
mkdir -p "${BOOTSTRAP_DIR}"

ensure_bootstrap_tls_pair "${BOOTSTRAP_CERT}" "${BOOTSTRAP_KEY}" \
  || fail "a first install with both TLS files absent did not bootstrap a pair"
[[ -s "${BOOTSTRAP_CERT}" && -s "${BOOTSTRAP_KEY}" ]] \
  || fail "the bootstrap TLS pair is missing or empty"
[[ "$(stat -c '%a' "${BOOTSTRAP_CERT}")" == "644" ]] \
  || fail "the bootstrap certificate mode is not 0644"
[[ "$(stat -c '%a' "${BOOTSTRAP_KEY}")" == "600" ]] \
  || fail "the bootstrap private-key mode is not 0600"
openssl x509 -in "${BOOTSTRAP_CERT}" -noout -subject \
  | grep -Eq 'CN[[:space:]]*=[[:space:]]*localhost' \
  || fail "the bootstrap certificate is not issued for localhost"
BOOTSTRAP_SAN="$(
  openssl x509 -in "${BOOTSTRAP_CERT}" -noout -ext subjectAltName
)"
grep -Fq 'DNS:localhost' <<< "${BOOTSTRAP_SAN}" \
  || fail "the bootstrap certificate has no localhost DNS SAN"
grep -Fq 'IP Address:127.0.0.1' <<< "${BOOTSTRAP_SAN}" \
  || fail "the bootstrap certificate has no loopback IP SAN"
assert_matching_pair "${BOOTSTRAP_CERT}" "${BOOTSTRAP_KEY}"

BOOTSTRAP_CERT_DIGEST="$(sha256sum "${BOOTSTRAP_CERT}")"
BOOTSTRAP_KEY_DIGEST="$(sha256sum "${BOOTSTRAP_KEY}")"
ensure_bootstrap_tls_pair "${BOOTSTRAP_CERT}" "${BOOTSTRAP_KEY}" \
  || fail "an existing complete TLS pair made package reconfiguration fail"
[[ "$(sha256sum "${BOOTSTRAP_CERT}")" == "${BOOTSTRAP_CERT_DIGEST}" ]] \
  || fail "package reconfiguration replaced an existing certificate"
[[ "$(sha256sum "${BOOTSTRAP_KEY}")" == "${BOOTSTRAP_KEY_DIGEST}" ]] \
  || fail "package reconfiguration replaced an existing private key"

MANUAL_DIR="${TEST_ROOT}/manual"
MANUAL_CERT="${MANUAL_DIR}/nginx.crt"
MANUAL_KEY="${MANUAL_DIR}/nginx-nopass.key"
mkdir -p "${MANUAL_DIR}"
openssl req -x509 -nodes -days 30 -newkey rsa:2048 \
  -keyout "${MANUAL_KEY}" \
  -out "${MANUAL_CERT}" \
  -subj '/CN=operator.example.test' \
  -addext 'subjectAltName=DNS:operator.example.test' \
  >/dev/null 2>&1
MANUAL_CERT_DIGEST="$(sha256sum "${MANUAL_CERT}")"
MANUAL_KEY_DIGEST="$(sha256sum "${MANUAL_KEY}")"
ensure_bootstrap_tls_pair "${MANUAL_CERT}" "${MANUAL_KEY}" \
  || fail "an operator-managed TLS pair made package reconfiguration fail"
[[ "$(sha256sum "${MANUAL_CERT}")" == "${MANUAL_CERT_DIGEST}" ]] \
  || fail "package reconfiguration replaced the operator certificate"
[[ "$(sha256sum "${MANUAL_KEY}")" == "${MANUAL_KEY_DIGEST}" ]] \
  || fail "package reconfiguration replaced the operator private key"

CERT_ONLY_DIR="${TEST_ROOT}/certificate-only"
CERT_ONLY_CERT="${CERT_ONLY_DIR}/nginx.crt"
CERT_ONLY_KEY="${CERT_ONLY_DIR}/nginx-nopass.key"
mkdir -p "${CERT_ONLY_DIR}"
cp "${MANUAL_CERT}" "${CERT_ONLY_CERT}"
CERT_ONLY_DIGEST="$(sha256sum "${CERT_ONLY_CERT}")"
if ensure_bootstrap_tls_pair "${CERT_ONLY_CERT}" "${CERT_ONLY_KEY}" \
    2>"${CERT_ONLY_DIR}/error"; then
  fail "a certificate without its private key did not fail closed"
fi
[[ "$(sha256sum "${CERT_ONLY_CERT}")" == "${CERT_ONLY_DIGEST}" ]] \
  || fail "the certificate-only state was overwritten"
[[ ! -e "${CERT_ONLY_KEY}" && ! -L "${CERT_ONLY_KEY}" ]] \
  || fail "a missing private key was silently generated"
grep -Fq 'partial operator-managed TLS configuration' \
  "${CERT_ONLY_DIR}/error" \
  || fail "certificate-only failure is not actionable"

KEY_ONLY_DIR="${TEST_ROOT}/private-key-only"
KEY_ONLY_CERT="${KEY_ONLY_DIR}/nginx.crt"
KEY_ONLY_KEY="${KEY_ONLY_DIR}/nginx-nopass.key"
mkdir -p "${KEY_ONLY_DIR}"
cp "${MANUAL_KEY}" "${KEY_ONLY_KEY}"
KEY_ONLY_DIGEST="$(sha256sum "${KEY_ONLY_KEY}")"
if ensure_bootstrap_tls_pair "${KEY_ONLY_CERT}" "${KEY_ONLY_KEY}" \
    2>"${KEY_ONLY_DIR}/error"; then
  fail "a private key without its certificate did not fail closed"
fi
[[ "$(sha256sum "${KEY_ONLY_KEY}")" == "${KEY_ONLY_DIGEST}" ]] \
  || fail "the private-key-only state was overwritten"
[[ ! -e "${KEY_ONLY_CERT}" && ! -L "${KEY_ONLY_CERT}" ]] \
  || fail "a missing certificate was silently generated"
grep -Fq 'partial operator-managed TLS configuration' \
  "${KEY_ONLY_DIR}/error" \
  || fail "private-key-only failure is not actionable"

FAKE_BIN="${TEST_ROOT}/bin"
PRERM_LOG="${TEST_ROOT}/prerm.log"
mkdir -p "${FAKE_BIN}"
for command_name in systemctl rm rmdir; do
  cat > "${FAKE_BIN}/${command_name}" <<'STUB'
#!/usr/bin/env bash
printf '%s\t%s\n' "$(basename -- "$0")" "$*" >> "${PRERM_TEST_LOG:?}"
STUB
  chmod 0755 "${FAKE_BIN}/${command_name}"
done

for action in remove deconfigure upgrade; do
  : > "${PRERM_LOG}"
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  PRERM_TEST_LOG="${PRERM_LOG}" \
    bash "${PRERM}" "${action}" 1.0.0
  if grep -Eq 'nginx\.crt|nginx-nopass\.key' "${PRERM_LOG}"; then
    fail "prerm ${action} attempted to delete an operator-managed TLS file"
  fi
done
if grep -Eq \
    'rm[[:space:]].*(nginx\.crt|nginx-nopass\.key)' \
    "${PRERM}"; then
  fail "prerm contains a TLS certificate or private-key deletion"
fi

echo "Debian TLS lifecycle tests passed."
