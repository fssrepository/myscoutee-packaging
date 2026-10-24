#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}"
export MYSCOUTEE_PACKAGING_PROJECT_ROOT="$REPO_ROOT"
IDENTITY_SCRIPT="${REPO_ROOT}/build/scripts/ensure-deployment-identity.sh"
BACKUP_SCRIPT="${REPO_ROOT}/build/scripts/backup-production.sh"
RESTORE_SCRIPT="${REPO_ROOT}/build/scripts/restore-production.sh"
TEST_ROOT="$(mktemp -d /tmp/myscoutee-registry-packaging-test.XXXXXX)"

cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT
mkdir -p "${TEST_ROOT}/debian"
python3 "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py" "${REPO_ROOT}/packaging" "${TEST_ROOT}/debian" --hook all
python3 "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py" "${REPO_ROOT}/packaging" "${TEST_ROOT}/postrm"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

canonical_hash() {
  local digest

  digest="$(printf '%s\n' "$@" | openssl dgst -sha256 -r | awk '{ print $1 }')"
  printf 'sha256:%s' "${digest}"
}

assert_file_mode() {
  local expected="$1"
  local file="$2"
  local actual

  actual="$(stat -c '%a' "${file}")"
  [[ "${actual}" == "${expected}" ]] || fail "${file} mode is ${actual}, expected ${expected}"
}

KEY_DIR="${TEST_ROOT}/identity"
STATE_DIR="${TEST_ROOT}/state"

MYSCOUTEE_REGISTRY_KEY_DIR="${KEY_DIR}" \
MYSCOUTEE_REGISTRY_STATE_DIR="${STATE_DIR}" \
  bash "${IDENTITY_SCRIPT}" >/dev/null

PRIVATE_KEY="${KEY_DIR}/deployment-private-key.pem"
PUBLIC_KEY="${KEY_DIR}/deployment-public-key.der"
[[ -s "${PRIVATE_KEY}" ]] || fail "first install did not create the private key"
[[ -s "${PUBLIC_KEY}" ]] || fail "first install did not create the public key"
[[ "$(stat -c '%s' "${PUBLIC_KEY}")" == "44" ]] || fail "SPKI DER public key is not 44 bytes"
assert_file_mode 600 "${PRIVATE_KEY}"
assert_file_mode 644 "${PUBLIC_KEY}"
assert_file_mode 700 "${KEY_DIR}"
assert_file_mode 700 "${STATE_DIR}"

private_hash_before="$(sha256sum "${PRIVATE_KEY}" | awk '{ print $1 }')"
public_hash_before="$(sha256sum "${PUBLIC_KEY}" | awk '{ print $1 }')"

MYSCOUTEE_REGISTRY_KEY_DIR="${KEY_DIR}" \
MYSCOUTEE_REGISTRY_STATE_DIR="${STATE_DIR}" \
  bash "${IDENTITY_SCRIPT}" >/dev/null

[[ "$(sha256sum "${PRIVATE_KEY}" | awk '{ print $1 }')" == "${private_hash_before}" ]] \
  || fail "rerun rotated the deployment private key"
[[ "$(sha256sum "${PUBLIC_KEY}" | awk '{ print $1 }')" == "${public_hash_before}" ]] \
  || fail "rerun changed the deployment public key"

cp "${PUBLIC_KEY}" "${TEST_ROOT}/expected-public.der"
rm -f "${PUBLIC_KEY}"
MYSCOUTEE_REGISTRY_KEY_DIR="${KEY_DIR}" \
MYSCOUTEE_REGISTRY_STATE_DIR="${STATE_DIR}" \
  bash "${IDENTITY_SCRIPT}" >/dev/null
cmp -s "${TEST_ROOT}/expected-public.der" "${PUBLIC_KEY}" \
  || fail "missing public key was not reconstructed from the preserved private key"

printf 'mismatched-public-key' > "${PUBLIC_KEY}"
if MYSCOUTEE_REGISTRY_KEY_DIR="${KEY_DIR}" \
  MYSCOUTEE_REGISTRY_STATE_DIR="${STATE_DIR}" \
  bash "${IDENTITY_SCRIPT}" >/dev/null 2>&1; then
  fail "mismatched public key was accepted"
fi
[[ "$(sha256sum "${PRIVATE_KEY}" | awk '{ print $1 }')" == "${private_hash_before}" ]] \
  || fail "mismatch handling modified the private key"
cp "${TEST_ROOT}/expected-public.der" "${PUBLIC_KEY}"
chmod 0644 "${PUBLIC_KEY}"

ORPHAN_KEY_DIR="${TEST_ROOT}/orphan-identity"
ORPHAN_STATE_DIR="${TEST_ROOT}/orphan-state"
mkdir -p "${ORPHAN_STATE_DIR}"
printf '%s\n' '{"deployment_id":"dep_preserved_without_key"}' \
  > "${ORPHAN_STATE_DIR}/deployment-state.json"
if MYSCOUTEE_REGISTRY_KEY_DIR="${ORPHAN_KEY_DIR}" \
  MYSCOUTEE_REGISTRY_STATE_DIR="${ORPHAN_STATE_DIR}" \
  bash "${IDENTITY_SCRIPT}" >/dev/null 2>&1; then
  fail "new identity was generated over preserved registry state"
fi

SYMLINK_STATE_KEY_DIR="${TEST_ROOT}/symlink-state-identity"
SYMLINK_STATE_DIR="${TEST_ROOT}/preserved-symlink-state"
mkdir -p "${SYMLINK_STATE_DIR}"
ln -s "${TEST_ROOT}/missing-state-target" "${SYMLINK_STATE_DIR}/preserved-entry"
if MYSCOUTEE_REGISTRY_KEY_DIR="${SYMLINK_STATE_KEY_DIR}" \
  MYSCOUTEE_REGISTRY_STATE_DIR="${SYMLINK_STATE_DIR}" \
  bash "${IDENTITY_SCRIPT}" >/dev/null 2>&1; then
  fail "new identity was generated over a symbolic-link state entry"
fi

deployment_fingerprint="sha256:$(sha256sum "${PUBLIC_KEY}" | awk '{ print $1 }')"
deployment_id="dep_0123456789abcdef0123456789abcdef"
registry_private_key="${TEST_ROOT}/registry-private-key.pem"
registry_public_key="${TEST_ROOT}/registry-public-key.der"
registration_message="${TEST_ROOT}/registration-receipt-message"
registration_signature_file="${TEST_ROOT}/registration-receipt-signature"
batch_message="${TEST_ROOT}/batch-receipt-message"
batch_signature_file="${TEST_ROOT}/batch-receipt-signature"
openssl genpkey -algorithm ED25519 -out "${registry_private_key}"
openssl pkey \
  -in "${registry_private_key}" \
  -pubout \
  -outform DER \
  -out "${registry_public_key}"
registry_public_key_base64="$(base64 -w 0 "${registry_public_key}")"
registry_fingerprint="sha256:$(sha256sum "${registry_public_key}" | awk '{ print $1 }')"
registry_key_id="rkey_${registry_fingerprint#sha256:}"
registry_key_id="${registry_key_id:0:37}"
zero_hash="sha256:0000000000000000000000000000000000000000000000000000000000000000"
batch_id="batch_0123456789abcdef0123456789abcdef"
registration_idempotency_key="registration_packaging_test"
installation_idempotency_key="installation_packaging_test"
registered_at="2026-07-28T00:00:00Z"
accepted_at="2026-07-28T00:00:01Z"
printf '%s\n' \
  "myscoutee-registry-registration-receipt-v1" \
  "1" \
  "test-program:parent-a" \
  "${deployment_id}" \
  "${deployment_fingerprint}" \
  "${registered_at}" \
  "${registry_key_id}" > "${registration_message}"
openssl pkeyutl \
  -sign \
  -inkey "${registry_private_key}" \
  -rawin \
  -in "${registration_message}" \
  -out "${registration_signature_file}"
registration_signature="$(base64 -w 0 "${registration_signature_file}")"
commitment_hash="$(canonical_hash \
  "myscoutee-registry-installation-test-v1" \
  "${deployment_id}" \
  "${installation_idempotency_key}")"
batch_hash="$(canonical_hash \
  "myscoutee-registry-mau-batch-payload-v1" \
  "installation-test" \
  "2026-07" \
  "installation-test-v1" \
  "0" \
  "${commitment_hash}")"
entry_hash="$(canonical_hash \
  "myscoutee-registry-ledger-entry-v1" \
  "1" \
  "test-program:parent-a" \
  "1" \
  "INSTALLATION_TEST_BATCH_ACCEPTED" \
  "${deployment_id}" \
  "${batch_id}" \
  "installation-test" \
  "2026-07" \
  "installation-test-v1" \
  "0" \
  "${batch_hash}" \
  "${zero_hash}" \
  "${accepted_at}")"
printf '%s\n' \
  "myscoutee-registry-mau-receipt-v1" \
  "1" \
  "test-program:parent-a" \
  "${batch_id}" \
  "${deployment_id}" \
  "1" \
  "${entry_hash}" \
  "${zero_hash}" \
  "${batch_hash}" \
  "installation-test" \
  "2026-07" \
  "installation-test-v1" \
  "0" \
  "${accepted_at}" \
  "2026-07-28" \
  "${registry_key_id}" > "${batch_message}"
openssl pkeyutl \
  -sign \
  -inkey "${registry_private_key}" \
  -rawin \
  -in "${batch_message}" \
  -out "${batch_signature_file}"
batch_signature="$(base64 -w 0 "${batch_signature_file}")"
jq -n \
  --arg deployment_fingerprint "${deployment_fingerprint}" \
  --arg deployment_id "${deployment_id}" \
  --arg registry_key_id "${registry_key_id}" \
  --arg registry_fingerprint "${registry_fingerprint}" \
  --arg registry_public_key "${registry_public_key_base64}" \
  --arg registration_signature "${registration_signature}" \
  --arg registration_idempotency_key "${registration_idempotency_key}" \
  --arg installation_idempotency_key "${installation_idempotency_key}" \
  --arg registered_at "${registered_at}" \
  --arg accepted_at "${accepted_at}" \
  --arg entry_hash "${entry_hash}" \
  --arg batch_hash "${batch_hash}" \
  --arg batch_signature "${batch_signature}" \
  --arg zero_hash "${zero_hash}" \
  --arg batch_id "${batch_id}" \
  '{
    schema_version: 1,
    protocol_version: "1",
    registry_scope: "test-program:parent-a",
    public_key_fingerprint: $deployment_fingerprint,
    registration_idempotency_key: $registration_idempotency_key,
    registration_software_version: "packaging-test",
    installation_idempotency_key: $installation_idempotency_key,
    installation_period: "2026-07",
    trusted_registry_key_fingerprint: $registry_fingerprint,
    deployment_id: $deployment_id,
    registration: {
      receipt: {
        protocol_version: "1",
        registry_scope: "test-program:parent-a",
        deployment_id: $deployment_id,
        registered_at: $registered_at,
        public_key_fingerprint: $deployment_fingerprint,
        registry_key_id: $registry_key_id,
        registry_public_key: $registry_public_key,
        receipt_signature: $registration_signature,
        duplicate: false
      }
    },
    installation_batch: {
      protocol_version: "1",
      registry_scope: "test-program:parent-a",
      batch_id: $batch_id,
      deployment_id: $deployment_id,
      idempotency_key: $installation_idempotency_key,
      duplicate: false,
      receipt: {
        ledger_index: 1,
        entry_hash: $entry_hash,
        previous_entry_hash: $zero_hash,
        batch_hash: $batch_hash,
        kind: "installation-test",
        period: "2026-07",
        ruleset_version: "installation-test-v1",
        qualified_mau_count: 0,
        accepted_at: $accepted_at,
        checkpoint_date: "2026-07-28",
        registry_scope: "test-program:parent-a",
        registry_key_id: $registry_key_id,
        registry_public_key: $registry_public_key,
        signature: $batch_signature
      }
    },
    updated_at: "2026-07-28T00:00:02Z"
  }' > "${STATE_DIR}/deployment-state.json"
jq '.installation_batch' "${STATE_DIR}/deployment-state.json" \
  > "${STATE_DIR}/receipts/installation-test-${batch_id}.json"

SERVER_DIR="${TEST_ROOT}/server"
BACKUP_DIR="${TEST_ROOT}/backups"
STUB_DIR="${TEST_ROOT}/stubs"
CONFIG_SOURCE_DIR="${TEST_ROOT}/config-source"
CONFIGURATION_KEY_DIR="${TEST_ROOT}/configuration-key"
mkdir -p \
  "${SERVER_DIR}" \
  "${BACKUP_DIR}" \
  "${STUB_DIR}" \
  "${CONFIG_SOURCE_DIR}" \
  "${CONFIGURATION_KEY_DIR}"
printf '5%.0s' {1..64} > "${CONFIGURATION_KEY_DIR}/deployment-master-key"
printf '\n' >> "${CONFIGURATION_KEY_DIR}/deployment-master-key"
chmod 0640 "${CONFIGURATION_KEY_DIR}/deployment-master-key"
printf '%s\n' 'REGISTRY_EXPECTED_KEY_FINGERPRINT=sha256:test-only' \
  > "${CONFIG_SOURCE_DIR}/myscoutee.env"
printf '%s\n' 'MONGO_APP_PASSWORD=test-only' \
  > "${CONFIG_SOURCE_DIR}/myscoutee.secrets.env"
ln -s "${CONFIG_SOURCE_DIR}/myscoutee.env" "${SERVER_DIR}/.env"
ln -s "${CONFIG_SOURCE_DIR}/myscoutee.secrets.env" "${SERVER_DIR}/.env.secrets"

cat > "${STUB_DIR}/docker" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "ps" ]]; then
  printf '%s\n' mongodb
fi
exit 0
STUB
cat > "${STUB_DIR}/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod 0755 "${STUB_DIR}/docker" "${STUB_DIR}/systemctl"

backup_path="$(
  PATH="${STUB_DIR}:${PATH}" \
  MYSCOUTEE_SERVER_DIR="${SERVER_DIR}" \
  MYSCOUTEE_BACKUP_DIR="${BACKUP_DIR}" \
  MYSCOUTEE_CONFIGURATION_KEY_DIR="${CONFIGURATION_KEY_DIR}" \
  MYSCOUTEE_REGISTRY_KEY_DIR="${KEY_DIR}" \
  MYSCOUTEE_REGISTRY_STATE_DIR="${STATE_DIR}" \
    bash "${BACKUP_SCRIPT}" 2>/dev/null
)"

[[ -s "${backup_path}" ]] || fail "backup archive was not created"
assert_file_mode 600 "${backup_path}"
tar -tzf "${backup_path}" | grep -q './registry/keys/deployment-private-key.pem' \
  || fail "backup omitted the deployment private key"
tar -tzf "${backup_path}" \
  | grep -q './configuration/deployment-master-key' \
  || fail "backup omitted the operator configuration master key"
tar -tzf "${backup_path}" | grep -q './registry/keys/deployment-public-key.der' \
  || fail "backup omitted the deployment public key"
tar -tzf "${backup_path}" | grep -q './registry/state/deployment-state.json' \
  || fail "backup omitted deployment registry state"
tar -tzf "${backup_path}" \
  | grep -q "./registry/state/receipts/installation-test-${batch_id}.json" \
  || fail "backup omitted deployment registry receipts"
BACKUP_INSPECT_DIR="${TEST_ROOT}/backup-inspect"
mkdir -p "${BACKUP_INSPECT_DIR}"
tar -C "${BACKUP_INSPECT_DIR}" -xzf "${backup_path}"
[[ -f "${BACKUP_INSPECT_DIR}/config/.env" \
  && ! -L "${BACKUP_INSPECT_DIR}/config/.env" ]] \
  || fail "backup preserved the installed .env symlink instead of its contents"
[[ -f "${BACKUP_INSPECT_DIR}/config/.env.secrets" \
  && ! -L "${BACKUP_INSPECT_DIR}/config/.env.secrets" ]] \
  || fail "backup preserved the installed secrets symlink instead of its contents"
grep -q 'REGISTRY_EXPECTED_KEY_FINGERPRINT=sha256:test-only' \
  "${BACKUP_INSPECT_DIR}/config/.env" \
  || fail "backup omitted registry trust configuration"
grep -q 'MONGO_APP_PASSWORD=test-only' \
  "${BACKUP_INSPECT_DIR}/config/.env.secrets" \
  || fail "backup omitted installed credentials"
jq -e \
  '.schemaVersion == 1
    and .complete == false
    and .components.operatorConfigurationKey == true' \
  "${BACKUP_INSPECT_DIR}/backup-manifest.json" >/dev/null \
  || fail "backup does not report its incomplete recovery components honestly"
if PATH="${STUB_DIR}:${PATH}" \
  MYSCOUTEE_SERVER_DIR="${SERVER_DIR}" \
  MYSCOUTEE_BACKUP_DIR="${TEST_ROOT}/required-complete-backups" \
  MYSCOUTEE_CONFIGURATION_KEY_DIR="${CONFIGURATION_KEY_DIR}" \
  MYSCOUTEE_REGISTRY_KEY_DIR="${KEY_DIR}" \
  MYSCOUTEE_REGISTRY_STATE_DIR="${STATE_DIR}" \
  MYSCOUTEE_BACKUP_REQUIRE_COMPLETE=true \
    bash "${BACKUP_SCRIPT}" >/dev/null 2>&1; then
  fail "required-complete backup accepted missing MongoDB, MinIO, or configuration"
fi

# An independent deployment has no Registry identity to back up. Exercise
# absence separately from damaged/partial identity and from other missing data.
INDEPENDENT_SERVER="${TEST_ROOT}/independent-server"
INDEPENDENT_KEYS="${TEST_ROOT}/independent-keys"
INDEPENDENT_STATE="${TEST_ROOT}/independent-state"
mkdir -p "${INDEPENDENT_SERVER}/data/minio"
printf 'services: {}\n' > "${INDEPENDENT_SERVER}/docker-compose-prod.yml"
printf 'MONGO_DATABASE=test\n' > "${INDEPENDENT_SERVER}/.env"
printf 'MONGO_APP_PASSWORD=test-only\n' > "${INDEPENDENT_SERVER}/.env.secrets"
printf 'user-owned-image-control\n' > "${INDEPENDENT_SERVER}/data/minio/image"
independent_backup() {
  PATH="${STUB_DIR}:${PATH}" \
  MYSCOUTEE_SERVER_DIR="${INDEPENDENT_SERVER}" \
  MYSCOUTEE_BACKUP_DIR="${TEST_ROOT}/independent-backups" \
  MYSCOUTEE_CONFIGURATION_KEY_DIR="${CONFIGURATION_KEY_DIR}" \
  MYSCOUTEE_REGISTRY_KEY_DIR="${INDEPENDENT_KEYS}" \
  MYSCOUTEE_REGISTRY_STATE_DIR="${INDEPENDENT_STATE}" \
  MYSCOUTEE_BACKUP_REQUIRE_COMPLETE=true \
    bash "${BACKUP_SCRIPT}"
}
for directory_state in absent empty; do
  if [[ "${directory_state}" == empty ]]; then
    mkdir -p "${INDEPENDENT_KEYS}" "${INDEPENDENT_STATE}"
  fi
  independent_path="$(independent_backup)"
  tar -xOzf "${independent_path}" ./backup-manifest.json \
    | jq -e '.complete == true and .registryIdentityRequired == false
      and .components.registryKeys == false and .components.minio == true
      and .missing == []' >/dev/null \
    || fail "independent backup misreported ${directory_state} Registry identity"
done
printf 'partial-private-key\n' > "${INDEPENDENT_KEYS}/deployment-private-key.pem"
if independent_backup >/dev/null 2>&1; then
  fail "complete backup accepted a partial Registry keypair"
fi
rm "${INDEPENDENT_KEYS}/deployment-private-key.pem"
printf '{}\n' > "${INDEPENDENT_STATE}/deployment-state.json"
if independent_backup >/dev/null 2>&1; then
  fail "complete backup accepted Registry state without its keys"
fi
rm "${INDEPENDENT_STATE}/deployment-state.json"
ln -s "${TEST_ROOT}/missing-key" "${INDEPENDENT_KEYS}/deployment-private-key.pem"
if independent_backup >/dev/null 2>&1; then
  fail "independent backup accepted a dangling Registry key symlink"
fi
rm "${INDEPENDENT_KEYS}/deployment-private-key.pem"
mv "${INDEPENDENT_SERVER}/data/minio" "${INDEPENDENT_SERVER}/data/minio-retained"
if independent_backup >/dev/null 2>&1; then
  fail "independent complete backup accepted missing MinIO data"
fi

EMBEDDED_NEWLINE_BACKUP_DIR="${TEST_ROOT}/embedded-newline-backup"
EMBEDDED_NEWLINE_BACKUP_PATH="${TEST_ROOT}/embedded-newline-backup.tar.gz"
mkdir -p "${EMBEDDED_NEWLINE_BACKUP_DIR}"
cp -a "${BACKUP_INSPECT_DIR}/." "${EMBEDDED_NEWLINE_BACKUP_DIR}/"
printf '8%.0s' {1..32} \
  > "${EMBEDDED_NEWLINE_BACKUP_DIR}/configuration/deployment-master-key"
printf '\n' \
  >> "${EMBEDDED_NEWLINE_BACKUP_DIR}/configuration/deployment-master-key"
printf '8%.0s' {1..32} \
  >> "${EMBEDDED_NEWLINE_BACKUP_DIR}/configuration/deployment-master-key"
tar -C "${EMBEDDED_NEWLINE_BACKUP_DIR}" \
  -czf "${EMBEDDED_NEWLINE_BACKUP_PATH}" .
if PATH="${STUB_DIR}:${PATH}" \
  CONFIRM_RESTORE=true \
  MYSCOUTEE_SERVER_DIR="${TEST_ROOT}/embedded-newline-restore" \
  MYSCOUTEE_CONFIGURATION_KEY_DIR="${TEST_ROOT}/embedded-newline-target" \
    bash "${RESTORE_SCRIPT}" "${EMBEDDED_NEWLINE_BACKUP_PATH}" \
      >/dev/null 2>&1; then
  fail "restore accepted an operator configuration key with an embedded newline"
fi

INCOMPLETE_BACKUP_DIR="${TEST_ROOT}/incomplete-backup"
INCOMPLETE_BACKUP_PATH="${TEST_ROOT}/incomplete-registry-backup.tar.gz"
mkdir -p "${INCOMPLETE_BACKUP_DIR}"
cp -a "${BACKUP_INSPECT_DIR}/." "${INCOMPLETE_BACKUP_DIR}/"
rm -f "${INCOMPLETE_BACKUP_DIR}/registry/state/deployment-state.json"
tar -C "${INCOMPLETE_BACKUP_DIR}" -czf "${INCOMPLETE_BACKUP_PATH}" .
if PATH="${STUB_DIR}:${PATH}" \
  CONFIRM_RESTORE=true \
  RESTORE_REGISTRY=true \
  MYSCOUTEE_SERVER_DIR="${TEST_ROOT}/incomplete-restore-server" \
  MYSCOUTEE_REGISTRY_KEY_DIR="${TEST_ROOT}/incomplete-restore-identity" \
  MYSCOUTEE_REGISTRY_STATE_DIR="${TEST_ROOT}/incomplete-restore-state" \
  bash "${RESTORE_SCRIPT}" "${INCOMPLETE_BACKUP_PATH}" >/dev/null 2>&1; then
  fail "restore accepted a deployment key without its matching registry state"
fi

MIXED_BACKUP_DIR="${TEST_ROOT}/mixed-backup"
MIXED_BACKUP_PATH="${TEST_ROOT}/mixed-registry-backup.tar.gz"
mkdir -p "${MIXED_BACKUP_DIR}"
cp -a "${BACKUP_INSPECT_DIR}/." "${MIXED_BACKUP_DIR}/"
sed -i \
  's/sha256:[0-9a-f]\{64\}/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
  "${MIXED_BACKUP_DIR}/registry/state/deployment-state.json"
tar -C "${MIXED_BACKUP_DIR}" -czf "${MIXED_BACKUP_PATH}" .
if PATH="${STUB_DIR}:${PATH}" \
  CONFIRM_RESTORE=true \
  RESTORE_REGISTRY=true \
  MYSCOUTEE_SERVER_DIR="${TEST_ROOT}/mixed-restore-server" \
  MYSCOUTEE_REGISTRY_KEY_DIR="${TEST_ROOT}/mixed-restore-identity" \
  MYSCOUTEE_REGISTRY_STATE_DIR="${TEST_ROOT}/mixed-restore-state" \
  bash "${RESTORE_SCRIPT}" "${MIXED_BACKUP_PATH}" >/dev/null 2>&1; then
  fail "restore accepted state bound to a different deployment key"
fi

TRUNCATED_BACKUP_DIR="${TEST_ROOT}/truncated-backup"
TRUNCATED_BACKUP_PATH="${TEST_ROOT}/truncated-registry-backup.tar.gz"
mkdir -p "${TRUNCATED_BACKUP_DIR}"
cp -a "${BACKUP_INSPECT_DIR}/." "${TRUNCATED_BACKUP_DIR}/"
head -c 240 "${BACKUP_INSPECT_DIR}/registry/state/deployment-state.json" \
  > "${TRUNCATED_BACKUP_DIR}/registry/state/deployment-state.json"
tar -C "${TRUNCATED_BACKUP_DIR}" -czf "${TRUNCATED_BACKUP_PATH}" .
if PATH="${STUB_DIR}:${PATH}" \
  CONFIRM_RESTORE=true \
  RESTORE_REGISTRY=true \
  MYSCOUTEE_SERVER_DIR="${TEST_ROOT}/truncated-restore-server" \
  MYSCOUTEE_REGISTRY_KEY_DIR="${TEST_ROOT}/truncated-restore-identity" \
  MYSCOUTEE_REGISTRY_STATE_DIR="${TEST_ROOT}/truncated-restore-state" \
  bash "${RESTORE_SCRIPT}" "${TRUNCATED_BACKUP_PATH}" >/dev/null 2>&1; then
  fail "restore accepted truncated deployment registry JSON"
fi

MALFORMED_RECEIPT_BACKUP_DIR="${TEST_ROOT}/malformed-receipt-backup"
MALFORMED_RECEIPT_BACKUP_PATH="${TEST_ROOT}/malformed-receipt-registry-backup.tar.gz"
mkdir -p "${MALFORMED_RECEIPT_BACKUP_DIR}"
cp -a "${BACKUP_INSPECT_DIR}/." "${MALFORMED_RECEIPT_BACKUP_DIR}/"
printf '%s' '{"protocol_version":"1"' \
  > "${MALFORMED_RECEIPT_BACKUP_DIR}/registry/state/receipts/installation-test-${batch_id}.json"
tar -C "${MALFORMED_RECEIPT_BACKUP_DIR}" -czf "${MALFORMED_RECEIPT_BACKUP_PATH}" .
if PATH="${STUB_DIR}:${PATH}" \
  CONFIRM_RESTORE=true \
  RESTORE_REGISTRY=true \
  MYSCOUTEE_SERVER_DIR="${TEST_ROOT}/malformed-receipt-restore-server" \
  MYSCOUTEE_REGISTRY_KEY_DIR="${TEST_ROOT}/malformed-receipt-restore-identity" \
  MYSCOUTEE_REGISTRY_STATE_DIR="${TEST_ROOT}/malformed-receipt-restore-state" \
  bash "${RESTORE_SCRIPT}" "${MALFORMED_RECEIPT_BACKUP_PATH}" >/dev/null 2>&1; then
  fail "restore accepted a malformed registry receipt"
fi

INVALID_SIGNATURE_BACKUP_DIR="${TEST_ROOT}/invalid-signature-backup"
INVALID_SIGNATURE_BACKUP_PATH="${TEST_ROOT}/invalid-signature-registry-backup.tar.gz"
mkdir -p "${INVALID_SIGNATURE_BACKUP_DIR}"
cp -a "${BACKUP_INSPECT_DIR}/." "${INVALID_SIGNATURE_BACKUP_DIR}/"
jq --arg signature "${batch_signature}" \
  '.registration.receipt.receipt_signature = $signature' \
  "${INVALID_SIGNATURE_BACKUP_DIR}/registry/state/deployment-state.json" \
  > "${INVALID_SIGNATURE_BACKUP_DIR}/registry/state/deployment-state.json.tmp"
mv \
  "${INVALID_SIGNATURE_BACKUP_DIR}/registry/state/deployment-state.json.tmp" \
  "${INVALID_SIGNATURE_BACKUP_DIR}/registry/state/deployment-state.json"
tar -C "${INVALID_SIGNATURE_BACKUP_DIR}" -czf "${INVALID_SIGNATURE_BACKUP_PATH}" .
if PATH="${STUB_DIR}:${PATH}" \
  CONFIRM_RESTORE=true \
  RESTORE_REGISTRY=true \
  MYSCOUTEE_SERVER_DIR="${TEST_ROOT}/invalid-signature-restore-server" \
  MYSCOUTEE_REGISTRY_KEY_DIR="${TEST_ROOT}/invalid-signature-restore-identity" \
  MYSCOUTEE_REGISTRY_STATE_DIR="${TEST_ROOT}/invalid-signature-restore-state" \
  bash "${RESTORE_SCRIPT}" "${INVALID_SIGNATURE_BACKUP_PATH}" >/dev/null 2>&1; then
  fail "restore accepted a registry state with an invalid central signature"
fi

UNRELATED_RECEIPT_BACKUP_DIR="${TEST_ROOT}/unrelated-receipt-backup"
UNRELATED_RECEIPT_BACKUP_PATH="${TEST_ROOT}/unrelated-receipt-registry-backup.tar.gz"
mkdir -p "${UNRELATED_RECEIPT_BACKUP_DIR}"
cp -a "${BACKUP_INSPECT_DIR}/." "${UNRELATED_RECEIPT_BACKUP_DIR}/"
jq '.duplicate = true' \
  "${UNRELATED_RECEIPT_BACKUP_DIR}/registry/state/receipts/installation-test-${batch_id}.json" \
  > "${UNRELATED_RECEIPT_BACKUP_DIR}/registry/state/receipts/installation-test-${batch_id}.json.tmp"
mv \
  "${UNRELATED_RECEIPT_BACKUP_DIR}/registry/state/receipts/installation-test-${batch_id}.json.tmp" \
  "${UNRELATED_RECEIPT_BACKUP_DIR}/registry/state/receipts/installation-test-${batch_id}.json"
tar -C "${UNRELATED_RECEIPT_BACKUP_DIR}" -czf "${UNRELATED_RECEIPT_BACKUP_PATH}" .
if PATH="${STUB_DIR}:${PATH}" \
  CONFIRM_RESTORE=true \
  RESTORE_REGISTRY=true \
  MYSCOUTEE_SERVER_DIR="${TEST_ROOT}/unrelated-receipt-restore-server" \
  MYSCOUTEE_REGISTRY_KEY_DIR="${TEST_ROOT}/unrelated-receipt-restore-identity" \
  MYSCOUTEE_REGISTRY_STATE_DIR="${TEST_ROOT}/unrelated-receipt-restore-state" \
  bash "${RESTORE_SCRIPT}" "${UNRELATED_RECEIPT_BACKUP_PATH}" >/dev/null 2>&1; then
  fail "restore accepted a standalone receipt that differs from deployment state"
fi

RESTORE_SERVER_DIR="${TEST_ROOT}/restore-server"
RESTORE_KEY_DIR="${TEST_ROOT}/restored-identity"
RESTORE_STATE_DIR="${TEST_ROOT}/restored-state"
RESTORE_CONFIGURATION_KEY_DIR="${TEST_ROOT}/restored-configuration-key"
mkdir -p "${RESTORE_SERVER_DIR}"

PATH="${STUB_DIR}:${PATH}" \
CONFIRM_RESTORE=true \
RESTORE_REGISTRY=true \
MYSCOUTEE_SERVER_DIR="${RESTORE_SERVER_DIR}" \
MYSCOUTEE_CONFIGURATION_KEY_DIR="${RESTORE_CONFIGURATION_KEY_DIR}" \
MYSCOUTEE_REGISTRY_KEY_DIR="${RESTORE_KEY_DIR}" \
MYSCOUTEE_REGISTRY_STATE_DIR="${RESTORE_STATE_DIR}" \
  bash "${RESTORE_SCRIPT}" "${backup_path}" >/dev/null

cmp -s "${PRIVATE_KEY}" "${RESTORE_KEY_DIR}/deployment-private-key.pem" \
  || fail "restore changed the deployment private key"
cmp -s \
  "${CONFIGURATION_KEY_DIR}/deployment-master-key" \
  "${RESTORE_CONFIGURATION_KEY_DIR}/deployment-master-key" \
  || fail "restore changed the operator configuration master key"
cmp -s "${TEST_ROOT}/expected-public.der" "${RESTORE_KEY_DIR}/deployment-public-key.der" \
  || fail "restore changed the deployment public key"
grep -q 'dep_0123456789abcdef0123456789abcdef' "${RESTORE_STATE_DIR}/deployment-state.json" \
  || fail "restore omitted deployment registry state"
assert_file_mode 600 "${RESTORE_KEY_DIR}/deployment-private-key.pem"
assert_file_mode 644 "${RESTORE_KEY_DIR}/deployment-public-key.der"

FAILED_RESTORE_STUB_DIR="${TEST_ROOT}/failed-restore-stubs"
FAILED_RESTORE_SERVER_DIR="${TEST_ROOT}/failed-restore-server"
FAILED_RESTORE_KEY_DIR="${TEST_ROOT}/failed-restore-configuration"
FAILED_RESTORE_LOG="${TEST_ROOT}/failed-restore-docker.log"
mkdir -p \
  "${FAILED_RESTORE_STUB_DIR}" \
  "${FAILED_RESTORE_SERVER_DIR}" \
  "${FAILED_RESTORE_KEY_DIR}"
printf '%s\n' 'FIREBASE_ENABLED=false' 'MONGO_REPLICA_SET_ENABLED=false' \
  > "${FAILED_RESTORE_SERVER_DIR}/.env"
printf '7%.0s' {1..64} > "${FAILED_RESTORE_KEY_DIR}/deployment-master-key"
printf '\n' >> "${FAILED_RESTORE_KEY_DIR}/deployment-master-key"
cat > "${FAILED_RESTORE_STUB_DIR}/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "ps" ]]; then
  printf '%s\n' myscoutee mongodb
  exit 0
fi
if [[ "${1:-}" == "exec" ]]; then
  exit 1
fi
if [[ "${1:-}" == "compose" && " $* " == *" stop profilemanagement "* ]]; then
  printf '%s\n' stop >> "${CONFIGURATION_RESTORE_TEST_LOG}"
  exit 0
fi
if [[ "${1:-}" == "compose" && " $* " == *" up -d --force-recreate profilemanagement "* ]]; then
  printf '%s\n' start >> "${CONFIGURATION_RESTORE_TEST_LOG}"
  exit 0
fi
exit 0
STUB
chmod 0755 "${FAILED_RESTORE_STUB_DIR}/docker"
if PATH="${FAILED_RESTORE_STUB_DIR}:${PATH}" \
  CONFIRM_RESTORE=true \
  CONFIGURATION_RESTORE_TEST_LOG="${FAILED_RESTORE_LOG}" \
  MYSCOUTEE_SERVER_DIR="${FAILED_RESTORE_SERVER_DIR}" \
  MYSCOUTEE_CONFIGURATION_KEY_DIR="${FAILED_RESTORE_KEY_DIR}" \
    bash "${RESTORE_SCRIPT}" "${backup_path}" >/dev/null 2>&1; then
  fail "restore accepted a failed MongoDB replacement"
fi
[[ "$(cat "${FAILED_RESTORE_LOG}")" == "stop" ]] \
  || fail "failed MongoDB restore restarted the backend"
[[ "$(tr -d '\n' < "${FAILED_RESTORE_KEY_DIR}/deployment-master-key")" \
  == "$(printf '7%.0s' {1..64})" ]] \
  || fail "failed MongoDB restore activated the backup encryption key"

SYMLINK_TARGET="${TEST_ROOT}/symlink-target"
SYMLINK_KEY_DIR="${TEST_ROOT}/symlink-identity"
mkdir -p "${SYMLINK_TARGET}"
ln -s "${SYMLINK_TARGET}" "${SYMLINK_KEY_DIR}"
if PATH="${STUB_DIR}:${PATH}" \
  CONFIRM_RESTORE=true \
  RESTORE_REGISTRY=true \
  MYSCOUTEE_SERVER_DIR="${RESTORE_SERVER_DIR}" \
  MYSCOUTEE_REGISTRY_KEY_DIR="${SYMLINK_KEY_DIR}" \
  MYSCOUTEE_REGISTRY_STATE_DIR="${TEST_ROOT}/symlink-state" \
  bash "${RESTORE_SCRIPT}" "${backup_path}" >/dev/null 2>&1; then
  fail "restore accepted a symbolic-link key target"
fi

RACE_STUB_DIR="${TEST_ROOT}/race-stubs"
RACE_SERVER_DIR="${TEST_ROOT}/race-server"
RACE_KEY_DIR="${TEST_ROOT}/race-identity"
RACE_STATE_DIR="${TEST_ROOT}/race-state"
RACE_LOG="${TEST_ROOT}/race-docker.log"
mkdir -p "${RACE_STUB_DIR}" "${RACE_SERVER_DIR}"
printf '%s\n' 'FIREBASE_ENABLED=false' 'MONGO_REPLICA_SET_ENABLED=false' > "${RACE_SERVER_DIR}/.env"
cat > "${RACE_STUB_DIR}/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "ps" ]]; then
  printf '%s\n' myscoutee mongodb
  exit 0
fi
if [[ "${1:-}" == "compose" && " $* " == *" stop profilemanagement "* ]]; then
  [[ ! -e "${MYSCOUTEE_REGISTRY_KEY_DIR}/deployment-private-key.pem" ]]
  printf '%s\n' stop >> "${REGISTRY_RESTORE_TEST_LOG}"
  exit 0
fi
if [[ "${1:-}" == "compose" && " $* " == *" up -d --force-recreate profilemanagement "* ]]; then
  grep -q 'dep_0123456789abcdef0123456789abcdef' \
    "${MYSCOUTEE_REGISTRY_STATE_DIR}/deployment-state.json"
  printf '%s\n' start >> "${REGISTRY_RESTORE_TEST_LOG}"
  exit 0
fi
exit 0
STUB
chmod 0755 "${RACE_STUB_DIR}/docker"

PATH="${RACE_STUB_DIR}:${PATH}" \
CONFIRM_RESTORE=true \
RESTORE_REGISTRY=true \
REGISTRY_RESTORE_TEST_LOG="${RACE_LOG}" \
MYSCOUTEE_SERVER_DIR="${RACE_SERVER_DIR}" \
MYSCOUTEE_REGISTRY_KEY_DIR="${RACE_KEY_DIR}" \
MYSCOUTEE_REGISTRY_STATE_DIR="${RACE_STATE_DIR}" \
  bash "${RESTORE_SCRIPT}" "${backup_path}" >/dev/null

[[ "$(sed -n '1p' "${RACE_LOG}")" == "stop" ]] \
  || fail "registry restore did not stop the running backend before replacement"
[[ "$(sed -n '2p' "${RACE_LOG}")" == "start" ]] \
  || fail "registry restore did not recreate the backend after replacement"

if grep -Fxq '/opt/myscoutee/packaging/scripts/ensure-deployment-identity.sh' \
  "${TEST_ROOT}/debian/postinst"; then
  fail "postinst initializes a node identity before operator consent"
fi
jq -e '
  .ownedDirectories as $directories
  | all(["/etc/myscoutee/registry", "/var/lib/myscoutee/registry"][];
      . as $path | any($directories[]; .path==$path and .mode=="0700" and .uid==10001 and .gid==10001))
' "${REPO_ROOT}/config/packaging/templates/install-policy.json" >/dev/null \
  || fail "install policy does not retain the API-owned Registry directories"
grep -Eq '^Depends:.*openssl' "${TEST_ROOT}/debian/control" \
  || fail "openssl is not a hard package dependency"
grep -Eq '^Depends:.*jq' "${TEST_ROOT}/debian/control" \
  || fail "jq is not a hard dependency for guarded registry-state restore"
grep -Fxq 'REGISTRY_ENABLED=false' \
  "${REPO_ROOT}/config/packaging/templates/myscoutee.env" \
  || fail "package enables registry participation before operator consent"
grep -Fxq 'REGISTRY_OUTBOUND_ALLOWED=false' \
  "${REPO_ROOT}/config/packaging/templates/myscoutee.env" \
  || fail "package permits registry communication before operator consent"
grep -Fxq 'REGISTRY_OPERATOR_REGISTRATION_CONFIRMED=false' \
  "${REPO_ROOT}/config/packaging/templates/myscoutee.env" \
  || fail "package marks registry registration confirmed before operator consent"
grep -Fxq 'REGISTRY_BASE_URL=' \
  "${REPO_ROOT}/config/packaging/templates/myscoutee.env" \
  || fail "package preselects a registry endpoint"
grep -Fxq 'REGISTRY_SCOPE=' \
  "${REPO_ROOT}/config/packaging/templates/myscoutee.env" \
  || fail "package preselects a registry scope"
grep -Fxq 'REGISTRY_TRUST_ON_FIRST_USE=false' \
  "${REPO_ROOT}/config/packaging/templates/myscoutee.env" \
  || fail "package trusts a registry before operator inspection"
grep -Fxq 'OPERATOR_USER=' \
  "${REPO_ROOT}/config/packaging/templates/myscoutee.env" \
  || fail "package does not expose an explicit Firebase operator allowlist"
grep -Fxq 'OPERATOR_BOOTSTRAP_PASSWORD_SHA256=' \
  "${REPO_ROOT}/config/packaging/templates/myscoutee.secrets.env" \
  || fail "package does not expose an empty local Operator bootstrap digest placeholder"
grep -Fxq 'OPERATOR_BOOTSTRAP_EMAIL=' \
  "${REPO_ROOT}/config/packaging/templates/myscoutee.secrets.env" \
  || fail "package does not expose an empty local Operator bootstrap subject placeholder"
grep -q 'OPERATOR_BOOTSTRAP_EMAIL' \
  "${REPO_ROOT}/server/projects/profile/src/main/resources/application-prod.yaml" \
  || fail "production application does not bind the local Operator bootstrap subject"
grep -q 'OPERATOR_BOOTSTRAP_EMAIL' \
  "${REPO_ROOT}/server/projects/profile/src/main/resources/application-dev.yaml" \
  || fail "development application does not bind the local Operator bootstrap subject"
grep -q 'OPERATOR_BOOTSTRAP_PASSWORD_SHA256' \
  "${REPO_ROOT}/server/projects/profile/src/main/resources/application-prod.yaml" \
  || fail "production application does not bind the local Operator bootstrap digest"
grep -q 'OPERATOR_BOOTSTRAP_PASSWORD_SHA256' \
  "${REPO_ROOT}/server/projects/profile/src/main/resources/application-dev.yaml" \
  || fail "development application does not bind the local Operator bootstrap digest"
if grep -Eq '^[[:space:]]*(ADMIN_USER|DEV_USER|MEMBER_USER):' \
    "${REPO_ROOT}/config/packaging/compose/docker-compose.production.yml"; then
  fail "production Compose embeds a deployment administrator/developer identity"
fi
if grep -Eq '^[[:space:]]*ADMIN_USER=' \
    "${REPO_ROOT}/config/packaging/templates/myscoutee.env"; then
  fail "package template embeds a legacy administrator allow-list"
fi
for compose_file in \
  "${REPO_ROOT}/config/packaging/compose/docker-compose.production.yml" \
  "${REPO_ROOT}/server/docker-compose-prod.yml"; do
  grep -q '^[[:space:]]*- \.env\.secrets$' "${compose_file}" \
    || fail "${compose_file} does not pass the root-managed bootstrap subject and digest through env_file"
  if grep -Eq \
      '^[[:space:]]+OPERATOR_BOOTSTRAP_(EMAIL|PASSWORD_SHA256)[[:space:]]*:' \
      "${compose_file}"; then
    fail "${compose_file} shadows bootstrap subject/digest values supplied by .env.secrets"
  fi
done
grep -Fq 'BACKUP_DIR="/var/backups/${RELEASE_PROJECT_NAME}"' \
  "${REPO_ROOT}/build/scripts/backup-production.sh" \
  || fail "installed backups do not default outside the purgeable /opt tree"
if grep -Fq 'rm -rf /var/backups/myscoutee' \
    "${TEST_ROOT}/postrm"; then
  fail "package purge deletes the external deployment recovery archive"
fi
grep -Fq 'REGISTRY_DEMO_VOLUME_NAME' \
  "${TEST_ROOT}/postrm" \
  || fail "package purge leaves the seeded demo registry volume behind"
grep -Fq 'REGISTRY_DEMO_CLIENT_VOLUME_NAME' \
  "${TEST_ROOT}/postrm" \
  || fail "package purge leaves the demo registry client-state volume behind"
for managed_repository in \
  myscoutee-api \
  myscoutee-nginx \
  myscoutee-minio \
  myscoutee-registry; do
  grep -Fq "${managed_repository}" \
    "${TEST_ROOT}/postrm" \
    || fail "package purge leaves managed repository ${managed_repository} behind"
done
if grep -Fq 'MONGO_IMAGE' "${TEST_ROOT}/postrm" \
    || grep -Fq 'REDIS_IMAGE' "${TEST_ROOT}/postrm"; then
  fail "package purge removes shared upstream MongoDB or Redis images"
fi
export MYSCOUTEE_PACKAGING_PROJECT_ROOT="$REPO_ROOT"
OPERATOR_PURGE="${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/client-tools/purge.sh"
grep -Fq 'apt-get purge -y "$RELEASE_PROJECT_NAME"' "${OPERATOR_PURGE}" \
  || fail "Operator purge wrapper does not delegate to Debian package lifecycle"
if grep -Eq \
    'myscoutee-(api|nginx|minio|registry)|registry-demo|docker (image|volume)' \
    "${OPERATOR_PURGE}"; then
  fail "Operator purge wrapper duplicates package-owned Docker cleanup policy"
fi
if grep -Fq 'rm -rf /var/backups/myscoutee' \
    "${OPERATOR_PURGE}"; then
  fail "remote purge deletes the external deployment recovery archive"
fi
grep -Fq 'python3 "${SCRIPT_DIR}/stage-runtime.py" "${REPO_ROOT}" "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/scripts"' \
  "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/package-production.sh" \
  || fail "package staging does not include the deployment identity helper"
grep -Fq 'find "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/scripts"' \
  "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/package-production.sh" \
  || fail "package staging does not make the deployment identity helper executable"
grep -Fq 'sync -f "${KEY_DIR}"' "${IDENTITY_SCRIPT}" \
  || fail "deployment identity helper does not durably sync its key directory"
grep -Fq 'sync -f "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"' "${BACKUP_SCRIPT}" \
  || fail "production backup reports success before syncing its archive"
grep -Fq 'sync -f "${REGISTRY_STATE_DIR}"' "${REPO_ROOT}/build/scripts/recovery-project.sh" \
  || fail "registry restore reports success before syncing restored state"

for compose_file in \
  "${REPO_ROOT}/config/packaging/compose/docker-compose.production.yml" \
  "${REPO_ROOT}/server/docker-compose-prod.yml"; do
  grep -q 'REGISTRY_OUTBOUND_ALLOWED' "${compose_file}" \
    || fail "${compose_file} does not pass the outbound registry gate"
  grep -q 'REGISTRY_OPERATOR_REGISTRATION_CONFIRMED' "${compose_file}" \
    || fail "${compose_file} does not pass the operator confirmation gate"
  grep -q 'OPERATOR_USER' "${compose_file}" \
    || fail "${compose_file} does not pass the Firebase operator allowlist"
  grep -q ':/etc/myscoutee/registry:rw' "${compose_file}" \
    || fail "${compose_file} does not let the authenticated Java initializer persist registry keys"
  grep -q ':/var/lib/myscoutee/registry' "${compose_file}" \
    || fail "${compose_file} does not mount registry state read-write"
  grep -q 'REGISTRY_DEMO_BASE_URL.*http://registry:8080' "${compose_file}" \
    || fail "${compose_file} does not pin Explore to the internal demo registry"
  grep -q 'REGISTRY_DEMO_SCOPE.*demo:myscoutee' "${compose_file}" \
    || fail "${compose_file} does not pin the isolated demo registry scope"
  grep -q 'REGISTRY_DEMO_SEED.*true' "${compose_file}" \
    || fail "${compose_file} does not use the guarded demo registry seed mode"
  grep -Fq 'command: ["start-demo"]' "${compose_file}" \
    || fail "${compose_file} does not use the guarded demo-only entrypoint"
  grep -q 'registry-demo-data:/data' "${compose_file}" \
    || fail "${compose_file} does not isolate demo registry SQLite/signing state"
  grep -q 'registry-demo-client-data:/var/lib/myscoutee/registry-demo' "${compose_file}" \
    || fail "${compose_file} does not isolate Java Explore registry identity/state"
done

DEMO_DEV_COMPOSE="${REPO_ROOT}/server/docker-compose-dev.yml"
DEMO_DEV_PROFILE_SCRIPT="${REPO_ROOT}/server/docker/scripts/start_profilemanagement_dev.sh"
CANONICAL_DEV_COMPOSE="${REPO_ROOT}/server/docker-compose.yml"
DEMO_USERS="${REPO_ROOT}/server/docker/conf/mongodb/demo_db/users.json"
E2E_USERS="${REPO_ROOT}/server/docker/conf/mongodb/e2e_db/users.json"

grep -Fq -- '- docker-compose-dev.yml' "${CANONICAL_DEV_COMPOSE}" \
  || fail "canonical docker compose entrypoint does not include the normal dev stack"
if grep -Fq 'docker-compose.registry-local.yml' "${CANONICAL_DEV_COMPOSE}"; then
  fail "canonical dev Compose still depends on the removed registry overlay"
fi
if grep -Fq 'REGISTRY_DEMO_MODE' "${DEMO_DEV_COMPOSE}"; then
  fail "normal dev Compose still exposes the removed Java registry simulation mode"
fi
grep -Fq 'myscoutee-registry-dev-demo-data-v1' "${DEMO_DEV_COMPOSE}" \
  || fail "normal dev Compose does not use its explicit demo SQLite/signing-key volume"
grep -Fq 'GRADLE_USER_HOME: /workspace/.gradle-docker' "${DEMO_DEV_COMPOSE}" \
  || fail "normal dev Compose shares Gradle cache locks with host-side daemons"
grep -Fq 'start_profilemanagement_dev.sh' "${DEMO_DEV_COMPOSE}" \
  || fail "normal dev Compose does not serialize API startup before the continuous compiler"
bash -n "${DEMO_DEV_PROFILE_SCRIPT}" \
  || fail "normal dev profile startup script has invalid shell syntax"
grep -Fq 'Profilemanagement is ready; starting the continuous compiler' "${DEMO_DEV_PROFILE_SCRIPT}" \
  || fail "normal dev profile startup script starts both Gradle builds concurrently"
grep -Fq 'exec bash /scripts/frontend_auto_watch.sh' "${DEMO_DEV_COMPOSE}" \
  || fail "normal dev frontend sync hides watcher failures in a shell restart loop"
if grep -Fq 'WAIT_FOR_HOSTS: "profilemanagement:8080"' "${DEMO_DEV_COMPOSE}"; then
  fail "normal dev frontend sync is still coupled to API readiness"
fi
grep -Fq "bash -c '>/dev/tcp/127.0.0.1/8080'" "${DEMO_DEV_COMPOSE}" \
  || fail "normal dev API does not expose a direct readiness healthcheck"
grep -Fq '/workspace/data/registry-demo-keys/' "${DEMO_DEV_COMPOSE}" \
  || fail "local demo deployment keys are not separated from production keys"
grep -Fq '/workspace/data/registry-demo-state' "${DEMO_DEV_COMPOSE}" \
  || fail "local demo deployment state is not separated from production state"

for seed_file in "${DEMO_USERS}" "${E2E_USERS}"; do
  jq -e '
    ([.[] | select((.email | type)=="string") | .email | ascii_downcase] | length == (unique | length))
    and ([.[] | select(
      (.operator // false) == false
      and .hostTier != "Operator"
      and .hostTier != "Admin"
      and ((.email // "") | test("^member[0-9]+@myscoutee\\.local$"))
    )] | length == 53)
    and ([.[] | select(
      .hostTier == "Admin"
      and ((.email // "") | test("^admin[0-9]+@myscoutee\\.local$"))
    )] | length == 2)
  ' "${seed_file}" >/dev/null \
    || fail "${seed_file} does not contain one unique numbered email per demo member/admin"
  jq -e '
    [.[] | select(
      .userId == "operator@myscoutee.local"
      and .email == "operator1@myscoutee.local"
      and .operator == true
      and .hostTier == "Operator"
    )] | length == 1
  ' "${seed_file}" >/dev/null \
    || fail "${seed_file} does not contain exactly one selectable demo operator"
done

if docker compose version >/dev/null 2>&1; then
  # Fixed candidate inputs keep isolation checks independent of release bumps.
  registry_production_image="myscoutee-registry:9.8.7-prod"
  registry_development_image="myscoutee-registry:9.8.7-dev"
  COMPOSE_STAGE="${TEST_ROOT}/compose-stage"
  mkdir -p "${COMPOSE_STAGE}/projects/profile/secrets"
  cp "${REPO_ROOT}/config/packaging/compose/docker-compose.production.yml" \
    "${COMPOSE_STAGE}/docker-compose-prod.yml"
  cp "${REPO_ROOT}/server/.env.secrets.example" "${COMPOSE_STAGE}/.env.secrets"
  cp "${REPO_ROOT}/server/projects/profile/secrets/firebase-service-account.json.example" \
    "${COMPOSE_STAGE}/projects/profile/secrets/firebase-service-account.json"
  cp "${REPO_ROOT}/config/packaging/compose/docker-compose.production-replicaset.yml" "${COMPOSE_STAGE}/"
  cp "${REPO_ROOT}/server/docker-compose-stun.yml" "${COMPOSE_STAGE}/"
  PACKAGED_PROD_JSON="$(
    REGISTRY_DEMO_IMAGE="$registry_production_image" docker compose \
    --env-file "${REPO_ROOT}/config/packaging/templates/myscoutee.env" \
    -f "${COMPOSE_STAGE}/docker-compose-prod.yml" \
    config --format json
  )" \
    || fail "packaged production Compose configuration does not render"

  SOURCE_COMPOSE_STAGE="${TEST_ROOT}/source-compose-stage"
  mkdir -p "${SOURCE_COMPOSE_STAGE}/projects/profile/secrets"
  cp "${REPO_ROOT}/server/docker-compose-prod.yml" \
    "${SOURCE_COMPOSE_STAGE}/docker-compose-prod.yml"
  cp "${REPO_ROOT}/server/.env.secrets.example" \
    "${SOURCE_COMPOSE_STAGE}/.env.secrets"
  cp "${REPO_ROOT}/server/projects/profile/secrets/firebase-service-account.json.example" \
    "${SOURCE_COMPOSE_STAGE}/projects/profile/secrets/firebase-service-account.json"
  cmp -s \
    "${REPO_ROOT}/server/docker-compose-prod.yml" \
    "${SOURCE_COMPOSE_STAGE}/docker-compose-prod.yml" \
    || fail "isolated source production Compose fixture differs from source"
  cp "${REPO_ROOT}/server/"docker-compose{.replicaset,-stun}.yml "${SOURCE_COMPOSE_STAGE}/"
  SOURCE_PROD_JSON="$(
    REGISTRY_DEMO_IMAGE="$registry_production_image" docker compose \
    --project-directory "${SOURCE_COMPOSE_STAGE}" \
    --env-file "${REPO_ROOT}/config/packaging/templates/myscoutee.env" \
    -f "${SOURCE_COMPOSE_STAGE}/docker-compose-prod.yml" \
    config --format json
  )" \
    || fail "source production Compose configuration does not render with dummy secrets"

  for production_json in "${PACKAGED_PROD_JSON}" "${SOURCE_PROD_JSON}"; do
    jq -e --arg registry_image "$registry_production_image" '
      .services.registry.container_name == "registry-demo"
      and .services.registry.hostname == "registry"
      and .services.registry.image == $registry_image
      and .services.registry.command == ["start-demo"]
      and .services.registry.environment.REGISTRY_DEMO_SEED == "true"
      and .services.registry.environment.REGISTRY_SCOPE == "demo:myscoutee"
      and .services.registry.environment.REGISTRY_DATABASE_PATH
        == "/data/registry-demo.db"
      and .services.registry.environment.REGISTRY_SIGNING_KEY_PATH
        == "/data/registry-demo-signing-key.pem"
      and ((.services.registry.ports // []) | length == 0)
      and .services.registry.read_only == true
      and (.services.registry.cap_drop | index("ALL") != null)
      and .services.profilemanagement.environment.REGISTRY_DEMO_BASE_URL
        == "http://registry:8080"
      and .services.profilemanagement.environment.REGISTRY_DEMO_SCOPE
        == "demo:myscoutee"
      and .services.profilemanagement.environment.REGISTRY_BASE_URL == ""
      and .services.profilemanagement.environment.REGISTRY_SCOPE == ""
      and .volumes["registry-demo-data"].name
        == "myscoutee-registry-demo-data-v1"
      and .volumes["registry-demo-client-data"].name
        == "myscoutee-registry-demo-client-data-v1"
    ' <<<"${production_json}" >/dev/null \
      || fail "production Explore registry is not strictly internal and separate from REAL registry state"
  done

  DEV_COMPOSE_JSON="$(
    cd "${REPO_ROOT}/server"
    LOCAL_REGISTRY_IMAGE="$registry_development_image" docker compose config --format json
  )" || fail "canonical development Compose configuration does not render"
  jq -e --arg registry_image "$registry_development_image" '
    .services.registry.container_name == "registry"
    and .services.registry.image == $registry_image
    and .services.registry.command == ["start-demo"]
    and .services.registry.environment.REGISTRY_DEMO_SEED == "true"
    and .services.registry.environment.REGISTRY_SCOPE == "demo:myscoutee"
    and .services.registry.environment.REGISTRY_DATABASE_PATH == "/data/registry-demo.db"
    and .services.registry.environment.REGISTRY_SIGNING_KEY_PATH == "/data/registry-demo-signing-key.pem"
    and .volumes["registry-dev-demo-data"].name == "myscoutee-registry-dev-demo-data-v1"
    and .services.profilemanagement.environment.MONGODB_DATABASE == "demo_db"
    and .services.profilemanagement.environment.MEMBER_USER == "member1@myscoutee.local"
    and .services.profilemanagement.environment.OPERATOR_USER == "operator1@myscoutee.local"
    and .services.profilemanagement.environment.REGISTRY_DEMO_PRIVATE_KEY_PATH
      == "/workspace/data/registry-demo-keys/deployment-private-key.pem"
    and .services.profilemanagement.environment.REGISTRY_DEMO_STATE_DIR
      == "/workspace/data/registry-demo-state"
    and .services.profilemanagement.environment.REGISTRY_DEMO_BASE_URL
      == "http://registry:8080"
    and .services.profilemanagement.environment.REGISTRY_DEMO_SCOPE
      == "demo:myscoutee"
    and (.services.profilemanagement.environment | has("REGISTRY_ENABLED") | not)
    and (.services.profilemanagement.environment | has("REGISTRY_OUTBOUND_ALLOWED") | not)
    and (.services.profilemanagement.environment
      | has("REGISTRY_OPERATOR_REGISTRATION_CONFIRMED")
      | not)
    and (.services.profilemanagement.environment | has("REGISTRY_PRIVATE_KEY_PATH") | not)
    and (.services.profilemanagement.environment | has("REGISTRY_STATE_DIR") | not)
    and (.services.profilemanagement.environment | has("REGISTRY_DEMO_MODE") | not)
  ' <<<"${DEV_COMPOSE_JSON}" >/dev/null \
    || fail "canonical dev Compose mixes demo registry state with real registry configuration"
fi

echo "Registry packaging tests passed."
