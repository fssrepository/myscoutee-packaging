#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/release-project.sh"
release_project_load "${SCRIPT_DIR}" "$(stat -c %u "${BASH_SOURCE[0]}")" || {
  echo 'The package-owned release project policy is missing or unsafe.' >&2; exit 1;
}
umask 077

# Narrow privileged boundary for operator-approved TLS changes. Requests are
# fixed-shape JSON files; no command, path, image, or URL is accepted from the
# browser.

STATE_DIR="${MYSCOUTEE_TLS_STATE_DIR:-/var/lib/${RELEASE_PROJECT_NAME}/tls}"
ENV_FILE="${MYSCOUTEE_TLS_ENV_FILE:-/etc/${RELEASE_PROJECT_NAME}/${RELEASE_PROJECT_NAME}.env}"
SERVER_DIR="${MYSCOUTEE_TLS_SERVER_DIR:-${RELEASE_PROJECT_ROOT}/server}"
COMPOSE_WRAPPER="${MYSCOUTEE_TLS_COMPOSE_WRAPPER:-${RELEASE_PROJECT_ROOT}/packaging/scripts/myscoutee-compose.sh}"
CERTBOT_IMAGE="${CERT_BOT:-certbot/certbot:v5.4.0}"
CERTBOT_CONF="${SERVER_DIR}/data/certbot/conf"
CERTBOT_WWW="${SERVER_DIR}/data/certbot/www"
MANUAL_CERT="${SERVER_DIR}/docker/conf/nginx/keys/nginx.crt"
MANUAL_KEY="${SERVER_DIR}/docker/conf/nginx/keys/nginx-nopass.key"
API_UID="${MYSCOUTEE_API_USER_ID:-$RELEASE_PROJECT_UID}"
API_GID="${MYSCOUTEE_API_GROUP_ID:-$RELEASE_PROJECT_GID}"
WORKER_UID=0
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  WORKER_UID="${MYSCOUTEE_TLS_WORKER_USER_ID:-0}"
fi
REQUEST_DIR="${STATE_DIR}/inbox/requests"
PROCESSING_DIR="${STATE_DIR}/archive/processing"
JOB_ROOT="${STATE_DIR}/runtime/jobs"
CONFIGURATION_FILE="${STATE_DIR}/runtime/configuration.json"
MAX_REQUEST_BYTES=300000

timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

install_numeric_owned_directory() {
  local mode="$1"
  local owner_uid="$2"
  local owner_gid="$3"
  shift 3

  [[ "${owner_uid}" =~ ^[0-9]+$ && "${owner_gid}" =~ ^[0-9]+$ ]] || {
    echo "TLS directory ownership must use numeric IDs." >&2
    return 1
  }
  install -d -m "${mode}" -- "$@"
  chown "+${owner_uid}:+${owner_gid}" -- "$@"
  chmod "${mode}" -- "$@"
}

safe_domain() {
  local domain="$1"
  [[ -n "${domain}" && "${#domain}" -le 253 ]] || return 1
  [[ "${domain}" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  [[ "${domain}" != .* && "${domain}" != *. && "${domain}" != *..* ]] || return 1
  [[ "${domain}" == *.* ]] || return 1
  local label
  IFS='.' read -r -a labels <<< "${domain}"
  for label in "${labels[@]}"; do
    [[ -n "${label}" && "${#label}" -le 63 ]] || return 1
    [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

prepare_directories() {
  local path
  for path in \
    "${STATE_DIR}" "${STATE_DIR}/inbox" "${REQUEST_DIR}" \
    "${STATE_DIR}/archive" "${PROCESSING_DIR}" "${STATE_DIR}/runtime" \
    "${JOB_ROOT}" "${CERTBOT_CONF}" "${CERTBOT_WWW}"; do
    [[ "${path}" == /* && ! -L "${path}" ]] || {
      echo "Unsafe TLS state path: ${path}" >&2
      return 1
    }
  done
  install -d -m 0700 \
    "${STATE_DIR}" "${STATE_DIR}/inbox" "${STATE_DIR}/archive" \
    "${PROCESSING_DIR}" "${CERTBOT_CONF}"
  # This directory is bind-mounted read-only into the unprivileged API.
  # Keep the reader group's traversal permission across every worker run.
  install_numeric_owned_directory \
    0750 "${WORKER_UID}" "${API_GID}" "${STATE_DIR}/runtime"
  install_numeric_owned_directory \
    0700 "${API_UID}" "${API_GID}" "${REQUEST_DIR}"
  install_numeric_owned_directory \
    2750 "${WORKER_UID}" "${API_GID}" "${JOB_ROOT}"
  install -d -m 0755 "${CERTBOT_WWW}"
}

write_status() {
  local job_id="$1" phase="$2" percent="$3" message="$4"
  local configuration_json="${5:-null}"
  local job_dir="${JOB_ROOT}/${job_id}"
  local tmp

  install_numeric_owned_directory \
    2750 "${WORKER_UID}" "${API_GID}" "${job_dir}"
  tmp="$(mktemp "${job_dir}/.status.XXXXXX")"
  jq -n \
    --arg jobId "${job_id}" \
    --arg phase "${phase}" \
    --argjson percent "${percent}" \
    --arg message "${message}" \
    --arg updatedAt "$(timestamp)" \
    --argjson configuration "${configuration_json}" \
    '{
      jobId: $jobId,
      phase: $phase,
      percent: $percent,
      message: $message,
      updatedAt: $updatedAt,
      configuration: $configuration
    }' > "${tmp}"
  chmod 0640 "${tmp}"
  chown "+${WORKER_UID}:+${API_GID}" -- "${tmp}"
  mv -f -- "${tmp}" "${job_dir}/status.json"
}

upsert_env() {
  local key="$1" value="$2"
  local tmp
  [[ "${key}" =~ ^[A-Z0-9_]+$ && "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] \
    || return 1
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
  awk -v key="${key}" -v value="${value}" '
    BEGIN { replaced = 0 }
    $0 ~ ("^" key "=") {
      if (!replaced) print key "=" value
      replaced = 1
      next
    }
    { print }
    END { if (!replaced) print key "=" value }
  ' "${ENV_FILE}" > "${tmp}"
  chmod --reference="${ENV_FILE}" "${tmp}"
  chown --reference="${ENV_FILE}" "${tmp}"
  mv -f -- "${tmp}" "${ENV_FILE}"
  # systemd loaded the old EnvironmentFile when this worker started. Compose
  # gives inherited variables precedence over the updated file, so keep the
  # worker's child-process environment in sync with each committed setting.
  export "${key}=${value}"
}

test_domain() {
  local domain="$1"
  local token="myscoutee-tls-$RANDOM-$$"
  local challenge_dir="${CERTBOT_WWW}/.well-known/acme-challenge"
  local challenge="${challenge_dir}/${token}"
  local response

  getent ahosts "${domain}" >/dev/null 2>&1 || {
    echo "The domain does not resolve in public DNS." >&2
    return 1
  }
  install -d -m 0755 "${challenge_dir}"
  printf '%s' "${token}" > "${challenge}"
  chmod 0644 "${challenge}"
  response="$(curl --fail --silent --show-error --max-time 15 \
    "http://${domain}/.well-known/acme-challenge/${token}" || true)"
  rm -f -- "${challenge}"
  [[ "${response}" == "${token}" ]] || {
    echo "The ACME HTTP challenge path is not publicly reachable." >&2
    return 1
  }
}

validate_pair() {
  local certificate="$1" private_key="$2" domain="$3"
  local cert_public key_public

  openssl x509 -in "${certificate}" -noout >/dev/null
  openssl pkey -in "${private_key}" -noout >/dev/null
  cert_public="$(openssl x509 -in "${certificate}" -pubkey -noout \
    | openssl pkey -pubin -outform DER 2>/dev/null \
    | sha256sum | awk '{print $1}')"
  key_public="$(openssl pkey -in "${private_key}" -pubout -outform DER 2>/dev/null \
    | sha256sum | awk '{print $1}')"
  [[ -n "${cert_public}" && "${cert_public}" == "${key_public}" ]] || {
    echo "The certificate and private key do not match." >&2
    return 1
  }
  openssl x509 -in "${certificate}" -noout -checkend 86400 >/dev/null || {
    echo "The certificate is expired or expires within 24 hours." >&2
    return 1
  }
  openssl x509 -in "${certificate}" -noout -checkhost "${domain}" \
    | grep -Fq "does match certificate" || {
    echo "The certificate does not cover ${domain}." >&2
    return 1
  }
}

certificate_configuration() {
  local enabled="$1" mode="$2" domain="$3" email="$4" auto_renew="$5"
  local certificate="$6"
  local issuer expires_at
  issuer="$(openssl x509 -in "${certificate}" -noout -issuer \
    | sed 's/^issuer=//; s/^[[:space:]]*//')"
  expires_at="$(date -u -d "$(openssl x509 -in "${certificate}" -noout -enddate \
    | cut -d= -f2-)" '+%Y-%m-%dT%H:%M:%SZ')"
  jq -n \
    --argjson enabled "${enabled}" \
    --arg mode "${mode}" \
    --arg domain "${domain}" \
    --arg contactEmail "${email}" \
    --argjson autoRenew "${auto_renew}" \
    --arg certificateIssuer "${issuer}" \
    --arg certificateExpiresAt "${expires_at}" \
    --arg updatedAt "$(timestamp)" \
    '{
      capability: "AVAILABLE",
      unavailableReason: null,
      enabled: $enabled,
      mode: $mode,
      domain: $domain,
      contactEmail: $contactEmail,
      autoRenew: $autoRenew,
      certificateConfigured: true,
      certificateIssuer: $certificateIssuer,
      certificateExpiresAt: $certificateExpiresAt,
      updatedAt: $updatedAt
    }'
}

persist_configuration() {
  local configuration_json="$1"
  local tmp
  tmp="$(mktemp "${STATE_DIR}/runtime/.configuration.XXXXXX")"
  printf '%s\n' "${configuration_json}" > "${tmp}"
  chmod 0640 "${tmp}"
  chown "+${WORKER_UID}:+${API_GID}" -- "${tmp}"
  mv -f -- "${tmp}" "${CONFIGURATION_FILE}"
}

obtain_automatic_certificate() {
  local domain="$1" email="$2"
  docker run --rm \
    -v "${CERTBOT_CONF}:/etc/letsencrypt" \
    -v "${CERTBOT_WWW}:/var/www/certbot" \
    "${CERTBOT_IMAGE}" certonly --webroot \
    --webroot-path /var/www/certbot \
    --non-interactive --agree-tos --no-eff-email \
    --keep-until-expiring --email "${email}" -d "${domain}"
}

apply_request() {
  local request="$1" job_id="$2"
  local enabled mode domain email auto_renew
  local certificate_input key_input certificate_path key_path configuration_json
  local certificate_target_tmp key_target_tmp
  enabled="$(jq -r '.configuration.enabled' "${request}")"
  mode="$(jq -r '.configuration.mode' "${request}")"
  domain="$(jq -r '.configuration.domain // ""' "${request}" | tr '[:upper:]' '[:lower:]')"
  email="$(jq -r '.configuration.contactEmail // ""' "${request}" | tr '[:upper:]' '[:lower:]')"
  auto_renew="$(jq -r '.configuration.autoRenew' "${request}")"

  if [[ "${enabled}" != "true" ]]; then
    configuration_json="$(jq -n \
      --arg mode "${mode}" --arg domain "${domain}" --arg contactEmail "${email}" \
      --arg updatedAt "$(timestamp)" \
      '{
        capability: "AVAILABLE", unavailableReason: null, enabled: false,
        mode: $mode, domain: $domain, contactEmail: $contactEmail,
        autoRenew: false, certificateConfigured: false,
        certificateIssuer: null, certificateExpiresAt: null, updatedAt: $updatedAt
      }')"
    persist_configuration "${configuration_json}"
    write_status "${job_id}" COMPLETED 100 \
      "operator.configuration.tls.saved" "${configuration_json}"
    return
  fi

  safe_domain "${domain}"
  write_status "${job_id}" RUNNING 20 \
    "operator.configuration.tls.job.validating"
  if [[ "${mode}" == "AUTOMATIC" ]]; then
    [[ "${email}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || {
      echo "A valid certificate contact email is required." >&2
      return 1
    }
    test_domain "${domain}"
    write_status "${job_id}" RUNNING 45 \
      "operator.configuration.tls.job.issuing"
    obtain_automatic_certificate "${domain}" "${email}"
    certificate_path="${CERTBOT_CONF}/live/${domain}/fullchain.pem"
    key_path="${CERTBOT_CONF}/live/${domain}/privkey.pem"
    validate_pair "${certificate_path}" "${key_path}" "${domain}"
    upsert_env DOMAIN "${domain}"
    upsert_env LETSENCRYPT_ENABLED true
  else
    certificate_input="$(jq -r '.configuration.certificate // ""' "${request}")"
    key_input="$(jq -r '.configuration.privateKey // ""' "${request}")"
    if [[ -n "${certificate_input}" || -n "${key_input}" ]]; then
      [[ -n "${certificate_input}" && -n "${key_input}" ]] || return 1
      certificate_path="$(mktemp)"
      key_path="$(mktemp)"
      printf '%s\n' "${certificate_input}" > "${certificate_path}"
      printf '%s\n' "${key_input}" > "${key_path}"
      if ! validate_pair "${certificate_path}" "${key_path}" "${domain}"; then
        rm -f -- "${certificate_path}" "${key_path}"
        return 1
      fi
      certificate_target_tmp="${MANUAL_CERT}.tls-${job_id}"
      key_target_tmp="${MANUAL_KEY}.tls-${job_id}"
      if ! install -m 0644 "${certificate_path}" "${certificate_target_tmp}" \
          || ! install -m 0600 "${key_path}" "${key_target_tmp}"; then
        rm -f -- \
          "${certificate_path}" "${key_path}" \
          "${certificate_target_tmp}" "${key_target_tmp}"
        return 1
      fi
      rm -f -- "${certificate_path}" "${key_path}"
      mv -f -- "${certificate_target_tmp}" "${MANUAL_CERT}"
      mv -f -- "${key_target_tmp}" "${MANUAL_KEY}"
    fi
    validate_pair "${MANUAL_CERT}" "${MANUAL_KEY}" "${domain}"
    certificate_path="${MANUAL_CERT}"
    auto_renew=false
    upsert_env DOMAIN "${domain}"
    upsert_env LETSENCRYPT_ENABLED false
  fi
  upsert_env WEBSOCKET_ALLOWED_ORIGIN_PATTERNS \
    "https://${domain},$(jq -er '.hostTools.tls.localOrigins | join(",")' "$RELEASE_PROJECT_POLICY")"
  local url_environment
  while IFS= read -r url_environment; do
    upsert_env "$url_environment" "https://${domain}"
  done < <(jq -er '.hostTools.tls.applicationUrlEnvironmentKeys[]' "$RELEASE_PROJECT_POLICY")

  write_status "${job_id}" RUNNING 80 \
    "operator.configuration.tls.job.restarting"
  (
    cd "${SERVER_DIR}"
    "${COMPOSE_WRAPPER}" up -d --force-recreate nginx
  )
  configuration_json="$(certificate_configuration \
    true "${mode}" "${domain}" "${email}" "${auto_renew}" "${certificate_path}")"
  persist_configuration "${configuration_json}"
  write_status "${job_id}" COMPLETED 100 \
    "operator.configuration.tls.saved" "${configuration_json}"
}

test_request() {
  local request="$1" job_id="$2" action="$3"
  local mode domain certificate_input key_input certificate_path key_path
  mode="$(jq -r '.configuration.mode' "${request}")"
  domain="$(jq -r '.configuration.domain // ""' "${request}" | tr '[:upper:]' '[:lower:]')"
  safe_domain "${domain}"
  write_status "${job_id}" RUNNING 35 \
    "operator.configuration.tls.job.testing"
  if [[ "${action}" == "TEST_DOMAIN" ]]; then
    test_domain "${domain}"
    write_status "${job_id}" COMPLETED 100 \
      "operator.configuration.tls.test.domain.success"
    return
  fi
  if [[ "${mode}" == "AUTOMATIC" ]]; then
    certificate_path="${CERTBOT_CONF}/live/${domain}/fullchain.pem"
    key_path="${CERTBOT_CONF}/live/${domain}/privkey.pem"
  else
    certificate_input="$(jq -r '.configuration.certificate // ""' "${request}")"
    key_input="$(jq -r '.configuration.privateKey // ""' "${request}")"
    if [[ -n "${certificate_input}" && -n "${key_input}" ]]; then
      certificate_path="$(mktemp)"
      key_path="$(mktemp)"
      printf '%s\n' "${certificate_input}" > "${certificate_path}"
      printf '%s\n' "${key_input}" > "${key_path}"
    else
      certificate_path="${MANUAL_CERT}"
      key_path="${MANUAL_KEY}"
    fi
  fi
  if ! validate_pair "${certificate_path}" "${key_path}" "${domain}"; then
    [[ "${certificate_path}" == "${MANUAL_CERT}" \
      || "${certificate_path}" == "${CERTBOT_CONF}"/* ]] \
      || rm -f -- "${certificate_path}" "${key_path}"
    return 1
  fi
  [[ "${certificate_path}" == "${MANUAL_CERT}" \
    || "${certificate_path}" == "${CERTBOT_CONF}"/* ]] \
    || rm -f -- "${certificate_path}" "${key_path}"
  write_status "${job_id}" COMPLETED 100 \
    "operator.configuration.tls.test.certificate.success"
}

process_request() {
  local source="$1" name claim request job_id action strict error_file error
  name="$(basename -- "${source}")"
  [[ "${name}" =~ ^tls_[0-9a-f]{32}\.json$ && -f "${source}" && ! -L "${source}" ]] \
    || return 1
  [[ "$(stat -c '%s' "${source}")" -le "${MAX_REQUEST_BYTES}" ]] || return 1
  claim="${PROCESSING_DIR}/${name%.json}"
  mkdir -- "${claim}"
  mv -- "${source}" "${claim}/request.json"
  request="${claim}/request.json"
  job_id="${name%.json}"
  strict="$(jq -r '
    type == "object"
    and ((keys - ["schemaVersion","jobId","action","requestedAt","requestedBy","configuration"]) | length == 0)
    and .schemaVersion == 1
    and (.jobId | type == "string")
    and (.requestedBy | type == "string")
    and (.configuration | type == "object")
    and (.configuration.mode == "AUTOMATIC" or .configuration.mode == "MANUAL")
    and (.configuration.enabled | type == "boolean")
    and (.configuration.autoRenew | type == "boolean")
  ' "${request}" 2>/dev/null || true)"
  action="$(jq -r '.action // ""' "${request}")"
  if [[ "${strict}" != "true" \
    || "$(jq -r '.jobId' "${request}")" != "${job_id}" \
    || ! "${action}" =~ ^(APPLY|TEST_DOMAIN|TEST_CERTIFICATE)$ ]]; then
    write_status "${job_id}" REJECTED 100 \
      "operator.configuration.tls.job.rejected"
    rm -rf -- "${claim}"
    return 1
  fi
  write_status "${job_id}" RUNNING 5 \
    "operator.configuration.tls.job.started"
  error_file="$(mktemp)"
  if {
    if [[ "${action}" == "APPLY" ]]; then
      apply_request "${request}" "${job_id}"
    else
      test_request "${request}" "${job_id}" "${action}"
    fi
  } 2>"${error_file}"; then
    rm -f -- "${error_file}"
    rm -rf -- "${claim}"
    return 0
  fi
  error="$(tail -n 1 "${error_file}" | cut -c1-500)"
  rm -f -- "${error_file}"
  write_status "${job_id}" FAILED 100 \
    "${error:-operator.configuration.tls.test.failed}"
  rm -rf -- "${claim}"
  return 1
}

renew() {
  local enabled mode domain email auto_renew certificate_path key_path configuration_json
  local fingerprint_before fingerprint_after
  [[ -f "${CONFIGURATION_FILE}" && ! -L "${CONFIGURATION_FILE}" ]] || return 0
  enabled="$(jq -r '.enabled' "${CONFIGURATION_FILE}")"
  mode="$(jq -r '.mode' "${CONFIGURATION_FILE}")"
  auto_renew="$(jq -r '.autoRenew' "${CONFIGURATION_FILE}")"
  [[ "${enabled}" == "true" && "${mode}" == "AUTOMATIC" \
    && "${auto_renew}" == "true" ]] || return 0
  domain="$(jq -r '.domain' "${CONFIGURATION_FILE}")"
  email="$(jq -r '.contactEmail' "${CONFIGURATION_FILE}")"
  safe_domain "${domain}"
  certificate_path="${CERTBOT_CONF}/live/${domain}/fullchain.pem"
  fingerprint_before="$(
    openssl x509 -in "${certificate_path}" -outform DER 2>/dev/null \
      | sha256sum | awk '{print $1}' \
      || true
  )"
  docker run --rm \
    -v "${CERTBOT_CONF}:/etc/letsencrypt" \
    -v "${CERTBOT_WWW}:/var/www/certbot" \
    "${CERTBOT_IMAGE}" renew --webroot --webroot-path /var/www/certbot \
    --non-interactive
  key_path="${CERTBOT_CONF}/live/${domain}/privkey.pem"
  validate_pair "${certificate_path}" "${key_path}" "${domain}"
  fingerprint_after="$(
    openssl x509 -in "${certificate_path}" -outform DER \
      | sha256sum | awk '{print $1}'
  )"
  if [[ -n "${fingerprint_after}" \
    && "${fingerprint_after}" != "${fingerprint_before}" ]]; then
    (
      cd "${SERVER_DIR}"
      "${COMPOSE_WRAPPER}" up -d --force-recreate nginx
    )
  fi
  configuration_json="$(certificate_configuration \
    true AUTOMATIC "${domain}" "${email}" true "${certificate_path}")"
  persist_configuration "${configuration_json}"
}

main() {
  local request
  [[ "$(id -u)" == "0" ]] || {
    echo "The MyScoutee TLS worker must run as root." >&2
    exit 1
  }
  for command_name in \
    jq openssl docker curl getent awk sed stat date \
    sha256sum grep cut tail install mktemp; do
    command -v "${command_name}" >/dev/null || {
      echo "Required TLS command is missing: ${command_name}" >&2
      exit 1
    }
  done
  prepare_directories
  if [[ "${1:-}" == "--renew" ]]; then
    renew
    return
  fi
  shopt -s nullglob
  for request in "${REQUEST_DIR}"/tls_*.json; do
    process_request "${request}" || true
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
