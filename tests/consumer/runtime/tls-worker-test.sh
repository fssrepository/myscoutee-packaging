#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "TLS worker test failed: $1" >&2
  exit 1
}

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

export MYSCOUTEE_TLS_STATE_DIR="${TEST_ROOT}/state"
export MYSCOUTEE_TLS_ENV_FILE="${TEST_ROOT}/myscoutee.env"
export MYSCOUTEE_TLS_SERVER_DIR="${TEST_ROOT}/server"
export MYSCOUTEE_API_USER_ID="$(id -u)"
export MYSCOUTEE_API_GROUP_ID="$(id -g)"
export MYSCOUTEE_TLS_WORKER_USER_ID="$(id -u)"
export MYSCOUTEE_TLS_COMPOSE_WRAPPER="${TEST_ROOT}/compose-wrapper.sh"
export MYSCOUTEE_TLS_COMPOSE_LOG="${TEST_ROOT}/compose-wrapper.log"
mkdir -p \
  "${MYSCOUTEE_TLS_SERVER_DIR}/data/certbot/conf" \
  "${MYSCOUTEE_TLS_SERVER_DIR}/data/certbot/www" \
  "${MYSCOUTEE_TLS_SERVER_DIR}/docker/conf/nginx/keys"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\n" "$*" >> "${MYSCOUTEE_TLS_COMPOSE_LOG:?}"' \
  'for key in DOMAIN LETSENCRYPT_ENABLED WEBSOCKET_ALLOWED_ORIGIN_PATTERNS EMAIL_BASE_URL PAYMENT_SIMULATOR_PUBLIC_BASE_URL PAYMENT_SIMULATOR_APPLICATION_BASE_URL; do' \
  '  expected="$(sed -n "s/^${key}=//p" "${MYSCOUTEE_TLS_ENV_FILE}")"' \
  '  [[ "${!key-}" == "${expected}" ]] || { echo "Stale inherited TLS setting: ${key}" >&2; exit 1; }' \
  'done' \
  > "${MYSCOUTEE_TLS_COMPOSE_WRAPPER}"
chmod 0755 "${MYSCOUTEE_TLS_COMPOSE_WRAPPER}"
printf '%s\n' \
  'DOMAIN=localhost' \
  'LETSENCRYPT_ENABLED=false' \
  'WEBSOCKET_ALLOWED_ORIGIN_PATTERNS=https://localhost' \
  'EMAIL_BASE_URL=https://localhost' \
  'PAYMENT_SIMULATOR_PUBLIC_BASE_URL=https://localhost' \
  'PAYMENT_SIMULATOR_APPLICATION_BASE_URL=https://localhost' \
  > "${MYSCOUTEE_TLS_ENV_FILE}"

# Match systemd's EnvironmentFile behavior: child-process variables retain
# their old values unless the worker updates them after persisting a setting.
set -a
source "${MYSCOUTEE_TLS_ENV_FILE}"
set +a

# shellcheck source=../scripts/myscoutee-tls-worker.sh
source "${MYSCOUTEE_PACKAGING_PROJECT_ROOT:-$PWD}/build/scripts/myscoutee-tls-worker.sh"

safe_domain app.example.test \
  || fail "a valid public domain was rejected"
if safe_domain localhost || safe_domain '-bad.example.test'; then
  fail "an unsafe domain was accepted"
fi

CERTIFICATE="${TEST_ROOT}/certificate.pem"
PRIVATE_KEY="${TEST_ROOT}/private-key.pem"
openssl req -x509 -nodes -days 30 -newkey rsa:2048 \
  -keyout "${PRIVATE_KEY}" \
  -out "${CERTIFICATE}" \
  -subj '/CN=app.example.test' \
  -addext 'subjectAltName=DNS:app.example.test' \
  >/dev/null 2>&1
validate_pair "${CERTIFICATE}" "${PRIVATE_KEY}" app.example.test \
  || fail "a matching certificate and private key were rejected"
if validate_pair "${CERTIFICATE}" "${PRIVATE_KEY}" other.example.test \
    >/dev/null 2>&1; then
  fail "a certificate for another domain was accepted"
fi

prepare_directories
# The API traverses the runtime mount as a different user in production.
# Running this suite as the worker owner must not hide a lost group-read bit.
[[ "$(stat -c '%a:%g' "${STATE_DIR}/runtime")" == "750:${API_GID}" ]] \
  || fail "the API group cannot traverse the TLS runtime mount"
prepare_directories
[[ "$(stat -c '%a:%g' "${STATE_DIR}/runtime")" == "750:${API_GID}" ]] \
  || fail "worker preparation revoked API runtime access"
JOB_ID="tls_0123456789abcdef0123456789abcdef"
jq -n \
  --arg jobId "${JOB_ID}" \
  --arg certificate "$(cat "${CERTIFICATE}")" \
  --arg privateKey "$(cat "${PRIVATE_KEY}")" \
  '{
    schemaVersion: 1,
    jobId: $jobId,
    action: "TEST_CERTIFICATE",
    requestedAt: "2026-07-30T00:00:00Z",
    requestedBy: "operator-test",
    configuration: {
      enabled: true,
      mode: "MANUAL",
      domain: "app.example.test",
      contactEmail: "",
      autoRenew: false,
      certificate: $certificate,
      privateKey: $privateKey
    }
  }' > "${REQUEST_DIR}/${JOB_ID}.json"

process_request "${REQUEST_DIR}/${JOB_ID}.json" \
  || fail "the valid certificate test job failed"
jq -e '
  .jobId == "tls_0123456789abcdef0123456789abcdef"
  and .phase == "COMPLETED"
  and .percent == 100
  and .configuration == null
' "${JOB_ROOT}/${JOB_ID}/status.json" >/dev/null \
  || fail "the certificate test status is invalid"
if rg -l --fixed-strings \
    "$(sed -n '2p' "${PRIVATE_KEY}")" \
    "${MYSCOUTEE_TLS_STATE_DIR}" >/dev/null; then
  fail "private-key material remained in durable TLS state"
fi

MANUAL_JOB_ID="tls_11111111111111111111111111111111"
jq -n \
  --arg jobId "${MANUAL_JOB_ID}" \
  --arg certificate "$(cat "${CERTIFICATE}")" \
  --arg privateKey "$(cat "${PRIVATE_KEY}")" \
  '{
    schemaVersion: 1,
    jobId: $jobId,
    action: "APPLY",
    requestedAt: "2026-07-30T00:01:00Z",
    requestedBy: "operator-manual",
    configuration: {
      enabled: true,
      mode: "MANUAL",
      domain: "app.example.test",
      contactEmail: "",
      autoRenew: false,
      certificate: $certificate,
      privateKey: $privateKey
    }
  }' > "${REQUEST_DIR}/${MANUAL_JOB_ID}.json"

process_request "${REQUEST_DIR}/${MANUAL_JOB_ID}.json" \
  || fail "the manual TLS apply job failed"
grep -Fxq 'DOMAIN=app.example.test' "${MYSCOUTEE_TLS_ENV_FILE}" \
  || fail "manual mode did not persist the operator-selected domain"
grep -Fxq 'LETSENCRYPT_ENABLED=false' "${MYSCOUTEE_TLS_ENV_FILE}" \
  || fail "manual mode did not select the operator-managed certificate"
grep -Fxq \
  'WEBSOCKET_ALLOWED_ORIGIN_PATTERNS=https://app.example.test,https://localhost,https://127.0.0.1,http://localhost:8080,http://127.0.0.1:8080' \
  "${MYSCOUTEE_TLS_ENV_FILE}" \
  || fail "manual mode did not derive browser origins from the selected domain"
grep -Fxq 'EMAIL_BASE_URL=https://app.example.test' \
  "${MYSCOUTEE_TLS_ENV_FILE}" \
  || fail "manual mode did not derive application links from the selected domain"
grep -Fxq 'PAYMENT_SIMULATOR_PUBLIC_BASE_URL=https://app.example.test' \
  "${MYSCOUTEE_TLS_ENV_FILE}" \
  || fail "manual mode did not derive the simulator public origin"
grep -Fxq 'PAYMENT_SIMULATOR_APPLICATION_BASE_URL=https://app.example.test' \
  "${MYSCOUTEE_TLS_ENV_FILE}" \
  || fail "manual mode did not derive the simulator application origin"
[[ "$(stat -c '%a' "${MANUAL_CERT}")" == "644" ]] \
  || fail "the operator certificate mode is not 0644"
[[ "$(stat -c '%a' "${MANUAL_KEY}")" == "600" ]] \
  || fail "the operator private-key mode is not 0600"
jq -e '
  .enabled == true
  and .mode == "MANUAL"
  and .domain == "app.example.test"
  and .contactEmail == ""
  and .autoRenew == false
  and .certificateConfigured == true
' "${CONFIGURATION_FILE}" >/dev/null \
  || fail "manual TLS state does not reflect the popup values"

AUTO_CERTIFICATE="${TEST_ROOT}/automatic-certificate.pem"
AUTO_PRIVATE_KEY="${TEST_ROOT}/automatic-private-key.pem"
openssl req -x509 -nodes -days 30 -newkey rsa:2048 \
  -keyout "${AUTO_PRIVATE_KEY}" \
  -out "${AUTO_CERTIFICATE}" \
  -subj '/CN=auto.example.test' \
  -addext 'subjectAltName=DNS:auto.example.test' \
  >/dev/null 2>&1
test_domain() {
  [[ "$1" == "auto.example.test" ]]
}
obtain_automatic_certificate() {
  local domain="$1"
  local target="${CERTBOT_CONF}/live/${domain}"
  mkdir -p "${target}"
  install -m 0644 "${AUTO_CERTIFICATE}" "${target}/fullchain.pem"
  install -m 0600 "${AUTO_PRIVATE_KEY}" "${target}/privkey.pem"
}

AUTOMATIC_JOB_ID="tls_22222222222222222222222222222222"
jq -n \
  --arg jobId "${AUTOMATIC_JOB_ID}" \
  '{
    schemaVersion: 1,
    jobId: $jobId,
    action: "APPLY",
    requestedAt: "2026-07-30T00:02:00Z",
    requestedBy: "operator-automatic",
    configuration: {
      enabled: true,
      mode: "AUTOMATIC",
      domain: "auto.example.test",
      contactEmail: "operator@example.test",
      autoRenew: true,
      certificate: "",
      privateKey: ""
    }
  }' > "${REQUEST_DIR}/${AUTOMATIC_JOB_ID}.json"

process_request "${REQUEST_DIR}/${AUTOMATIC_JOB_ID}.json" \
  || fail "the automatic TLS apply job failed"
grep -Fxq 'DOMAIN=auto.example.test' "${MYSCOUTEE_TLS_ENV_FILE}" \
  || fail "automatic mode did not persist the operator-selected domain"
grep -Fxq 'LETSENCRYPT_ENABLED=true' "${MYSCOUTEE_TLS_ENV_FILE}" \
  || fail "automatic mode did not select the ACME certificate"
grep -Fxq 'EMAIL_BASE_URL=https://auto.example.test' \
  "${MYSCOUTEE_TLS_ENV_FILE}" \
  || fail "automatic mode did not update application links"
grep -Fxq 'PAYMENT_SIMULATOR_PUBLIC_BASE_URL=https://auto.example.test' \
  "${MYSCOUTEE_TLS_ENV_FILE}" \
  || fail "automatic mode did not update the simulator public origin"
grep -Fxq 'PAYMENT_SIMULATOR_APPLICATION_BASE_URL=https://auto.example.test' \
  "${MYSCOUTEE_TLS_ENV_FILE}" \
  || fail "automatic mode did not update the simulator application origin"
jq -e '
  .enabled == true
  and .mode == "AUTOMATIC"
  and .domain == "auto.example.test"
  and .contactEmail == "operator@example.test"
  and .autoRenew == true
  and .certificateConfigured == true
' "${CONFIGURATION_FILE}" >/dev/null \
  || fail "automatic TLS state does not reflect the popup values"
[[ "$(wc -l < "${MYSCOUTEE_TLS_COMPOSE_LOG}")" == "2" ]] \
  || fail "each applied TLS mode must recreate Nginx exactly once"
if rg -l --fixed-strings \
    "$(sed -n '2p' "${PRIVATE_KEY}")" \
    "${MYSCOUTEE_TLS_STATE_DIR}" >/dev/null; then
  fail "applied private-key material remained in durable TLS job state"
fi

echo "TLS worker tests passed."
