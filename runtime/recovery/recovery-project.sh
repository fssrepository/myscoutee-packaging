#!/usr/bin/env bash
# MyScoutee Registry recovery extension. Not selected by the template package.
default_registry_key_dir() {
  if [[ "${SERVER_DIR}" == "$(jq -er '.hostTools.registry.serverDirectory' "$RELEASE_PROJECT_POLICY")" ]]; then
    jq -er '.hostTools.registry.keyDirectory' "$RELEASE_PROJECT_POLICY"
  else
    printf '%s/data/registry-keys' "${SERVER_DIR}"
  fi
}

default_registry_state_dir() {
  if [[ "${SERVER_DIR}" == "$(jq -er '.hostTools.registry.serverDirectory' "$RELEASE_PROJECT_POLICY")" ]]; then
    jq -er '.hostTools.registry.stateDirectory' "$RELEASE_PROJECT_POLICY"
  else
    printf '%s/data/registry' "${SERVER_DIR}"
  fi
}


validate_registry_keypair() {
  local key_dir="$1"
  local derived_public

  if [[ -L "${key_dir}" || ! -d "${key_dir}" ]]; then
    echo "Registry backup key path must be a non-symlink directory." >&2
    return 1
  fi
  if [[ -L "${key_dir}/deployment-private-key.pem" \
    || -L "${key_dir}/deployment-public-key.der" ]]; then
    echo "Registry backup key files must not be symbolic links." >&2
    return 1
  fi
  if [[ ! -f "${key_dir}/deployment-private-key.pem" \
    || ! -f "${key_dir}/deployment-public-key.der" ]]; then
    echo "Registry backup does not contain a complete deployment keypair." >&2
    return 1
  fi
  if ! openssl pkey -in "${key_dir}/deployment-private-key.pem" -text -noout 2>/dev/null \
    | grep -q '^ED25519 Private-Key:'; then
    echo "Registry backup contains an invalid deployment Ed25519 private key." >&2
    return 1
  fi

  derived_public="$(mktemp "${WORK_DIR}/derived-registry-public.XXXXXX")"
  if ! openssl pkey \
    -in "${key_dir}/deployment-private-key.pem" \
    -pubout \
    -outform DER \
    -out "${derived_public}"; then
    rm -f "${derived_public}"
    echo "Unable to derive the deployment public key from the registry backup." >&2
    return 1
  fi
  if ! cmp -s "${derived_public}" "${key_dir}/deployment-public-key.der"; then
    rm -f "${derived_public}"
    echo "Registry backup public key does not match its deployment private key." >&2
    return 1
  fi
  rm -f "${derived_public}"
}

canonical_sha256() {
  local digest

  digest="$(printf '%s\n' "$@" | openssl dgst -sha256 -r | awk '{ print $1 }')"
  printf 'sha256:%s' "${digest}"
}

decode_canonical_base64() {
  local value="$1"
  local output_file="$2"
  local label="$3"
  local encoded_again

  if ! printf '%s' "${value}" | base64 --decode > "${output_file}" 2>/dev/null; then
    echo "Registry backup ${label} is not valid base64." >&2
    return 1
  fi
  encoded_again="$(base64 -w 0 "${output_file}")"
  if [[ "${encoded_again}" != "${value}" ]]; then
    echo "Registry backup ${label} is not canonical padded base64." >&2
    return 1
  fi
}

verify_registry_signature() {
  local public_key_file="$1"
  local signature_base64="$2"
  local message_file="$3"
  local label="$4"
  local signature_file

  signature_file="$(mktemp "${WORK_DIR}/registry-signature.XXXXXX")"
  decode_canonical_base64 "${signature_base64}" "${signature_file}" "${label} signature"
  if [[ "$(stat -c '%s' "${signature_file}")" -ne 64 ]]; then
    echo "Registry backup ${label} signature is not an Ed25519 signature." >&2
    return 1
  fi
  if ! openssl pkeyutl \
    -verify \
    -pubin \
    -inkey "${public_key_file}" \
    -keyform DER \
    -rawin \
    -in "${message_file}" \
    -sigfile "${signature_file}" >/dev/null 2>&1; then
    echo "Registry backup ${label} signature verification failed." >&2
    return 1
  fi
}

validate_installation_receipt_cryptography() {
  local state_file="$1"
  local receipt_file="$2"
  local registry_public_key_file="$3"
  local scope deployment_id installation_idempotency_key batch_id
  local kind period ruleset qualified_count accepted_at checkpoint_date
  local ledger_index entry_hash previous_entry_hash batch_hash registry_key_id
  local expected_commitment_hash expected_batch_hash expected_entry_hash signature
  local message_file

  scope="$(jq -r '.registry_scope' "${state_file}")"
  deployment_id="$(jq -r '.deployment_id' "${state_file}")"
  installation_idempotency_key="$(jq -r '.installation_idempotency_key' "${state_file}")"
  batch_id="$(jq -r '.batch_id' "${receipt_file}")"
  kind="$(jq -r '.receipt.kind' "${receipt_file}")"
  period="$(jq -r '.receipt.period' "${receipt_file}")"
  ruleset="$(jq -r '.receipt.ruleset_version' "${receipt_file}")"
  qualified_count="$(jq -r '.receipt.qualified_mau_count' "${receipt_file}")"
  accepted_at="$(jq -r '.receipt.accepted_at' "${receipt_file}")"
  checkpoint_date="$(jq -r '.receipt.checkpoint_date' "${receipt_file}")"
  ledger_index="$(jq -r '.receipt.ledger_index' "${receipt_file}")"
  entry_hash="$(jq -r '.receipt.entry_hash' "${receipt_file}")"
  previous_entry_hash="$(jq -r '.receipt.previous_entry_hash' "${receipt_file}")"
  batch_hash="$(jq -r '.receipt.batch_hash' "${receipt_file}")"
  registry_key_id="$(jq -r '.receipt.registry_key_id' "${receipt_file}")"
  signature="$(jq -r '.receipt.signature' "${receipt_file}")"

  expected_commitment_hash="$(canonical_sha256 \
    "myscoutee-registry-installation-test-v1" \
    "${deployment_id}" \
    "${installation_idempotency_key}")"
  expected_batch_hash="$(canonical_sha256 \
    "myscoutee-registry-mau-batch-payload-v1" \
    "${kind}" \
    "${period}" \
    "${ruleset}" \
    "${qualified_count}" \
    "${expected_commitment_hash}")"
  if [[ "${batch_hash}" != "${expected_batch_hash}" ]]; then
    echo "Registry backup installation receipt has an invalid batch hash." >&2
    return 1
  fi

  expected_entry_hash="$(canonical_sha256 \
    "myscoutee-registry-ledger-entry-v1" \
    "1" \
    "${scope}" \
    "${ledger_index}" \
    "INSTALLATION_TEST_BATCH_ACCEPTED" \
    "${deployment_id}" \
    "${batch_id}" \
    "${kind}" \
    "${period}" \
    "${ruleset}" \
    "${qualified_count}" \
    "${batch_hash}" \
    "${previous_entry_hash}" \
    "${accepted_at}")"
  if [[ "${entry_hash}" != "${expected_entry_hash}" ]]; then
    echo "Registry backup installation receipt has an invalid ledger entry hash." >&2
    return 1
  fi
  if [[ "${checkpoint_date}" != "${accepted_at:0:10}" ]]; then
    echo "Registry backup installation receipt has an inconsistent checkpoint date." >&2
    return 1
  fi

  message_file="$(mktemp "${WORK_DIR}/registry-batch-receipt-message.XXXXXX")"
  printf '%s\n' \
    "myscoutee-registry-mau-receipt-v1" \
    "1" \
    "${scope}" \
    "${batch_id}" \
    "${deployment_id}" \
    "${ledger_index}" \
    "${entry_hash}" \
    "${previous_entry_hash}" \
    "${batch_hash}" \
    "${kind}" \
    "${period}" \
    "${ruleset}" \
    "${qualified_count}" \
    "${accepted_at}" \
    "${checkpoint_date}" \
    "${registry_key_id}" > "${message_file}"
  verify_registry_signature \
    "${registry_public_key_file}" \
    "${signature}" \
    "${message_file}" \
    "installation receipt"
}

validate_registry_state_cryptography() {
  local state_file="$1"
  local receipt_directory="${state_file%/*}/receipts"
  local registry_public_key_file canonical_public_key_file message_file embedded_receipt
  local registry_public_key_base64 registry_fingerprint trusted_fingerprint registry_key_id
  local scope deployment_id registered_at deployment_fingerprint receipt_signature
  local expected_registry_key_id receipt_file expected_receipt_name
  local registration_present installation_present

  registration_present="$(jq -r '.registration != null' "${state_file}")"
  if [[ "${registration_present}" != "true" ]]; then
    return 0
  fi

  registry_public_key_base64="$(jq -r '.registration.receipt.registry_public_key' "${state_file}")"
  registry_public_key_file="$(mktemp "${WORK_DIR}/registry-public-key.XXXXXX")"
  canonical_public_key_file="$(mktemp "${WORK_DIR}/registry-public-key-canonical.XXXXXX")"
  decode_canonical_base64 \
    "${registry_public_key_base64}" \
    "${registry_public_key_file}" \
    "central public key"
  if ! openssl pkey \
    -pubin \
    -inform DER \
    -in "${registry_public_key_file}" \
    -text \
    -noout 2>/dev/null | grep -q '^ED25519 Public-Key:'; then
    echo "Registry backup central public key is not Ed25519 SPKI DER." >&2
    return 1
  fi
  if ! openssl pkey \
    -pubin \
    -inform DER \
    -in "${registry_public_key_file}" \
    -outform DER \
    -out "${canonical_public_key_file}" 2>/dev/null \
    || ! cmp -s "${registry_public_key_file}" "${canonical_public_key_file}"; then
    echo "Registry backup central public key is not canonical SPKI DER." >&2
    return 1
  fi

  registry_fingerprint="sha256:$(openssl dgst -sha256 -r \
    "${registry_public_key_file}" | awk '{ print $1 }')"
  trusted_fingerprint="$(jq -r '.trusted_registry_key_fingerprint' "${state_file}")"
  registry_key_id="$(jq -r '.registration.receipt.registry_key_id' "${state_file}")"
  expected_registry_key_id="rkey_${registry_fingerprint#sha256:}"
  expected_registry_key_id="${expected_registry_key_id:0:37}"
  if [[ "${trusted_fingerprint}" != "${registry_fingerprint}" \
    || "${registry_key_id}" != "${expected_registry_key_id}" ]]; then
    echo "Registry backup central key fingerprint or key ID is inconsistent." >&2
    return 1
  fi

  scope="$(jq -r '.registry_scope' "${state_file}")"
  deployment_id="$(jq -r '.deployment_id' "${state_file}")"
  registered_at="$(jq -r '.registration.receipt.registered_at' "${state_file}")"
  deployment_fingerprint="$(jq -r '.public_key_fingerprint' "${state_file}")"
  receipt_signature="$(jq -r '.registration.receipt.receipt_signature' "${state_file}")"
  message_file="$(mktemp "${WORK_DIR}/registry-registration-receipt-message.XXXXXX")"
  printf '%s\n' \
    "myscoutee-registry-registration-receipt-v1" \
    "1" \
    "${scope}" \
    "${deployment_id}" \
    "${deployment_fingerprint}" \
    "${registered_at}" \
    "${registry_key_id}" > "${message_file}"
  verify_registry_signature \
    "${registry_public_key_file}" \
    "${receipt_signature}" \
    "${message_file}" \
    "registration receipt"

  installation_present="$(jq -r '.installation_batch != null' "${state_file}")"
  if [[ "${installation_present}" == "true" ]]; then
    embedded_receipt="$(mktemp "${WORK_DIR}/registry-embedded-receipt.XXXXXX")"
    jq -S '.installation_batch' "${state_file}" > "${embedded_receipt}"
    validate_installation_receipt_cryptography \
      "${state_file}" \
      "${embedded_receipt}" \
      "${registry_public_key_file}"
  else
    embedded_receipt=""
  fi

  if [[ -d "${receipt_directory}" ]]; then
    while IFS= read -r -d '' receipt_file; do
      expected_receipt_name="installation-test-$(jq -r '.batch_id' "${receipt_file}").json"
      if [[ "$(basename "${receipt_file}")" != "${expected_receipt_name}" ]]; then
        echo "Registry backup receipt filename does not match its batch ID: ${receipt_file}" >&2
        return 1
      fi
      validate_installation_receipt_cryptography \
        "${state_file}" \
        "${receipt_file}" \
        "${registry_public_key_file}"
      if [[ -n "${embedded_receipt}" ]] \
        && ! diff -q \
          <(jq -S . "${receipt_file}") \
          "${embedded_receipt}" >/dev/null; then
        echo "Registry backup standalone receipt differs from deployment state." >&2
        return 1
      fi
    done < <(find "${receipt_directory}" -type f -print0)
  fi
}

validate_registry_state_binding() {
  local backup_key_dir="$1"
  local state_file="$2"
  local expected_fingerprint receipt_file
  local validator="${SCRIPT_DIR}/validate-registry-state.jq"

  if [[ "$(stat -c '%s' "${state_file}")" -le 0 \
    || "$(stat -c '%s' "${state_file}")" -gt 1048576 ]]; then
    echo "Registry backup deployment state exceeds the supported size limit." >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to validate registry state before restore." >&2
    return 1
  fi
  if [[ ! -r "${validator}" ]]; then
    echo "Registry state validator is missing: ${validator}" >&2
    return 1
  fi

  expected_fingerprint="sha256:$(openssl dgst -sha256 -r \
    "${backup_key_dir}/deployment-public-key.der" | awk '{ print $1 }')"
  if ! jq -e \
    --arg mode state \
    --arg expected_fingerprint "${expected_fingerprint}" \
    --slurpfile state "${state_file}" \
    -f "${validator}" \
    "${state_file}" >/dev/null; then
    echo "Registry backup deployment state is malformed, incomplete, or not bound to its deployment key." >&2
    return 1
  fi

  if [[ -d "${state_file%/*}/receipts" ]]; then
    while IFS= read -r -d '' receipt_file; do
      if [[ "$(stat -c '%s' "${receipt_file}")" -le 0 \
        || "$(stat -c '%s' "${receipt_file}")" -gt 1048576 ]]; then
        echo "Registry backup receipt has an invalid size: ${receipt_file}" >&2
        return 1
      fi
      if ! jq -e \
        --arg mode receipt \
        --arg expected_fingerprint "${expected_fingerprint}" \
        --slurpfile state "${state_file}" \
        -f "${validator}" \
        "${receipt_file}" >/dev/null; then
        echo "Registry backup contains a malformed or unrelated receipt: ${receipt_file}" >&2
        return 1
      fi
    done < <(find "${state_file%/*}/receipts" -type f -name '*.json' -print0)
  fi
  validate_registry_state_cryptography "${state_file}"
}

validate_registry_restore() {
  local backup_key_dir="$1"
  local backup_state_dir="$2"

  validate_registry_keypair "${backup_key_dir}"

  if [[ -L "${backup_state_dir}" || ! -d "${backup_state_dir}" ]]; then
    echo "Registry backup does not contain a non-symlink state directory." >&2
    return 1
  fi
  if [[ -L "${backup_state_dir}/deployment-state.json" \
    || ! -s "${backup_state_dir}/deployment-state.json" ]]; then
    echo "Registry backup does not contain complete deployment registry state." >&2
    return 1
  fi
  validate_registry_state_binding \
    "${backup_key_dir}" \
    "${backup_state_dir}/deployment-state.json"
  if [[ -L "${REGISTRY_KEY_DIR}" \
    || ( -e "${REGISTRY_KEY_DIR}" && ! -d "${REGISTRY_KEY_DIR}" ) ]]; then
    echo "Registry key restore target must be a non-symlink directory: ${REGISTRY_KEY_DIR}" >&2
    return 1
  fi
  if [[ -L "${REGISTRY_STATE_DIR}" \
    || ( -e "${REGISTRY_STATE_DIR}" && ! -d "${REGISTRY_STATE_DIR}" ) ]]; then
    echo "Registry state restore target must be a non-symlink directory: ${REGISTRY_STATE_DIR}" >&2
    return 1
  fi
  if [[ -L "${REGISTRY_KEY_DIR}/deployment-private-key.pem" \
    || -L "${REGISTRY_KEY_DIR}/deployment-public-key.der" ]]; then
    echo "Registry key restore targets must not be symbolic links." >&2
    return 1
  fi
  if [[ -e "${REGISTRY_KEY_DIR}/deployment-private-key.pem" \
    && ! -f "${REGISTRY_KEY_DIR}/deployment-private-key.pem" ]]; then
    echo "Registry private-key restore target is not a regular file." >&2
    return 1
  fi
  if [[ -e "${REGISTRY_KEY_DIR}/deployment-public-key.der" \
    && ! -f "${REGISTRY_KEY_DIR}/deployment-public-key.der" ]]; then
    echo "Registry public-key restore target is not a regular file." >&2
    return 1
  fi
  if [[ -e "${REGISTRY_STATE_DIR}/receipts" \
    && ( -L "${REGISTRY_STATE_DIR}/receipts" || ! -d "${REGISTRY_STATE_DIR}/receipts" ) ]]; then
    echo "Registry receipt restore target must be a non-symlink directory." >&2
    return 1
  fi
  if find "${backup_state_dir}" -type l -print -quit | grep -q .; then
    echo "Registry backup state must not contain symbolic links." >&2
    return 1
  fi
  if [[ -d "${REGISTRY_STATE_DIR}" ]] && find "${REGISTRY_STATE_DIR}" -type l -print -quit | grep -q .; then
    echo "Registry state restore target must not contain symbolic links." >&2
    return 1
  fi
}

restore_registry_identity() {
  local backup_key_dir="$1"
  local backup_state_dir="$2"
  local private_tmp public_tmp

  install -d -m 0700 "${REGISTRY_KEY_DIR}" "${REGISTRY_STATE_DIR}"
  install -d -m 0700 "${REGISTRY_STATE_DIR}/receipts"

  private_tmp="$(mktemp "${REGISTRY_KEY_DIR}/.deployment-private-key.pem.restore.XXXXXX")"
  public_tmp="$(mktemp "${REGISTRY_KEY_DIR}/.deployment-public-key.der.restore.XXXXXX")"
  install -m 0600 "${backup_key_dir}/deployment-private-key.pem" "${private_tmp}"
  install -m 0644 "${backup_key_dir}/deployment-public-key.der" "${public_tmp}"
  mv -f "${private_tmp}" "${REGISTRY_KEY_DIR}/deployment-private-key.pem"
  mv -f "${public_tmp}" "${REGISTRY_KEY_DIR}/deployment-public-key.der"

  # Restore state as an exact snapshot. Leaving receipts from the previous
  # identity/state pair behind would make the restored history ambiguous.
  find "${REGISTRY_STATE_DIR}" -mindepth 1 -depth -delete
  cp -a "${backup_state_dir}/." "${REGISTRY_STATE_DIR}/"

  chmod 0700 "${REGISTRY_KEY_DIR}" "${REGISTRY_STATE_DIR}"
  chmod 0600 "${REGISTRY_KEY_DIR}/deployment-private-key.pem"
  chmod 0644 "${REGISTRY_KEY_DIR}/deployment-public-key.der"
  if [[ -d "${REGISTRY_STATE_DIR}/receipts" ]]; then
    chmod 0700 "${REGISTRY_STATE_DIR}/receipts"
  fi
  if [[ "${EUID}" -eq 0 ]]; then
    chown -R --no-dereference \
      "+${MYSCOUTEE_API_UID:-$RELEASE_PROJECT_UID}:+${MYSCOUTEE_API_GID:-$RELEASE_PROJECT_GID}" \
      "${REGISTRY_KEY_DIR}" "${REGISTRY_STATE_DIR}"
  fi

  sync -f "${REGISTRY_KEY_DIR}/deployment-private-key.pem"
  sync -f "${REGISTRY_KEY_DIR}/deployment-public-key.der"
  sync -f "${REGISTRY_STATE_DIR}/deployment-state.json"
  sync -f "${REGISTRY_KEY_DIR}"
  sync -f "${REGISTRY_STATE_DIR}"
}

project_recovery_init() {
  registry_keys_complete=false
  registry_state_complete=false
  registry_identity_required=false
  registry_key_dir_value="${REGISTRY_KEY_DIR_HOST:-$(read_env_file_value REGISTRY_KEY_DIR_HOST "${ENV_FILE}" || true)}"
  registry_state_dir_value="${REGISTRY_STATE_DIR_HOST:-$(read_env_file_value REGISTRY_STATE_DIR_HOST "${ENV_FILE}" || true)}"
  REGISTRY_KEY_DIR="${MYSCOUTEE_REGISTRY_KEY_DIR:-$(resolve_host_path "${registry_key_dir_value:-$(default_registry_key_dir)}")}"
  REGISTRY_STATE_DIR="${MYSCOUTEE_REGISTRY_STATE_DIR:-$(resolve_host_path "${registry_state_dir_value:-$(default_registry_state_dir)}")}"
}

project_backup() {
  mkdir -p "${WORK_DIR}/registry"
  # Registry enrollment is optional. Require its recovery components as soon as
  # either directory contains identity/state material; never treat a partial
  # identity as an unconfigured deployment. Failed inspection must abort backup.
  for registry_dir in "${REGISTRY_KEY_DIR}" "${REGISTRY_STATE_DIR}"; do
    if [[ -L "${registry_dir}" ]]; then
      echo "Deployment registry backup paths must not be symbolic links." >&2
      exit 1
    elif [[ -d "${registry_dir}" ]]; then
      registry_entry="$(find "${registry_dir}" -mindepth 1 -print -quit)"
      if [[ -n "${registry_entry}" ]]; then
        registry_identity_required=true
      fi
    elif [[ -e "${registry_dir}" ]]; then
      echo "Deployment registry backup paths must be directories." >&2
      exit 1
    fi
  done

  if [[ -L "${REGISTRY_KEY_DIR}" \
    || -L "${REGISTRY_KEY_DIR}/deployment-private-key.pem" \
    || -L "${REGISTRY_KEY_DIR}/deployment-public-key.der" ]]; then
    echo "Deployment registry key backup paths must not be symbolic links." >&2
    exit 1
  elif [[ -f "${REGISTRY_KEY_DIR}/deployment-private-key.pem" \
    && -f "${REGISTRY_KEY_DIR}/deployment-public-key.der" ]]; then
    if find "${REGISTRY_KEY_DIR}" -type l -print -quit | grep -q .; then
      echo "Deployment registry key directory must not contain symbolic links." >&2
      exit 1
    fi
    mkdir -p "${WORK_DIR}/registry/keys"
    cp -a "${REGISTRY_KEY_DIR}/." "${WORK_DIR}/registry/keys/"
    registry_keys_complete=true
  elif [[ "${registry_identity_required}" == "true" ]]; then
    missing_components+=("registry-keys")
    echo "Warning: deployment registry keypair was not found under ${REGISTRY_KEY_DIR}; identity backup skipped." >&2
  fi

  if [[ -L "${REGISTRY_STATE_DIR}" ]]; then
    echo "Deployment registry state backup path must not be a symbolic link." >&2
    exit 1
  elif [[ -d "${REGISTRY_STATE_DIR}" ]]; then
    if find "${REGISTRY_STATE_DIR}" -type l -print -quit | grep -q .; then
      echo "Deployment registry state backup path must not contain symbolic links." >&2
      exit 1
    fi
    mkdir -p "${WORK_DIR}/registry/state"
    cp -a "${REGISTRY_STATE_DIR}/." "${WORK_DIR}/registry/state/"
    registry_state_complete=true
  elif [[ "${registry_identity_required}" == "true" ]]; then
    missing_components+=("registry-state")
    echo "Warning: deployment registry state was not found under ${REGISTRY_STATE_DIR}; registry state backup skipped." >&2
  fi

}

project_backup_manifest() {
  jq -n --argjson required "$registry_identity_required" --argjson keys "$registry_keys_complete" --argjson state "$registry_state_complete" \
    '{registryIdentityRequired:$required,components:{registryKeys:$keys,registryState:$state}}'
}

project_restore_validate() {
  if [[ "${RESTORE_REGISTRY:-false}" == "true" ]]; then
    if [[ ! -d "${WORK_DIR}/registry/keys" ]]; then
      echo "RESTORE_REGISTRY=true, but the backup has no deployment registry identity." >&2
      exit 1
    fi
    validate_registry_restore "${WORK_DIR}/registry/keys" "${WORK_DIR}/registry/state"
  fi
}

project_restore() {
  if [[ "${RESTORE_REGISTRY:-false}" == "true" ]]; then
    stop_restore_backend
    RESTORE_INCOMPLETE=true
    restore_registry_identity "${WORK_DIR}/registry/keys" "${WORK_DIR}/registry/state"
    RESTORE_INCOMPLETE=false
  fi
}
