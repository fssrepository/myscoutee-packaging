#!/usr/bin/env bash
# Source-checkout package audit; deliberately not installed by the DEB.
set -euo pipefail

STAGING_DIR="${1:-}"
if [[ -z "${STAGING_DIR}" || ! -d "${STAGING_DIR}" ]]; then
  echo "Usage: audit-package-credentials.sh <staged-package-root>" >&2
  exit 2
fi
STAGING_DIR="$(cd -- "${STAGING_DIR}" && pwd -P)"
AUDIT_TMP="$(mktemp -d /tmp/myscoutee-package-credential-audit.XXXXXX)"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}"
source "${SCRIPT_DIR}/../lib/release-project.sh"
release_project_load "${REPO_ROOT}/config/packaging" "$(id -u)" || {
  echo 'Invalid release project policy.' >&2; exit 1;
}
PACKAGING_SOURCE="${MYSCOUTEE_PACKAGING_SOURCE:-${SCRIPT_DIR}/../..}"
NESTED_ARCHIVE_AUDIT="${PACKAGING_SOURCE}/release/audit/audit-nested-archive.py"
PRIVATE_KEY_AUDIT="${PACKAGING_SOURCE}/release/signing/private_key_material.py"
source "${SCRIPT_DIR}/audit-project-seeds.sh"
source "${SCRIPT_DIR}/../lib/release-config.sh"
release_config_load "${REPO_ROOT}"

cleanup() {
  rm -rf "${AUDIT_TMP}"
}
trap cleanup EXIT
printf '%s\n' "$RELEASE_SETTINGS" > "${AUDIT_TMP}/release-settings.json"
python3 "${SCRIPT_DIR}/render-social-filters.py" "${AUDIT_TMP}/release-settings.json" "${AUDIT_TMP}"

for command_name in jq python3 tar; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Package credential audit requires ${command_name}." >&2
    exit 2
  fi
done
if [[ ! -f "${NESTED_ARCHIVE_AUDIT}" ]]; then
  echo "Nested archive credential audit helper is missing." >&2
  exit 2
fi
if [[ ! -f "${PRIVATE_KEY_AUDIT}" ]]; then
  echo "Private-key credential audit helper is missing." >&2
  exit 2
fi

is_forbidden_path() {
  awk '
    {
      path = tolower($0)
      sub(/^\.\//, "", path)
      if (path ~ /(^|\/)firebase-service-account\.json$/ \
          || path ~ /(^|\/)\.env\.secrets$/ \
          || path ~ /(^|\/)application-secrets\.ya?ml$/ \
          || path ~ /(^|\/)[^/]*(client-secret|provider-credentials)[^/]*\.json$/ \
          || path ~ /(^|\/)(id_rsa|id_dsa|id_ecdsa|id_ed25519)$/ \
          || path ~ /(^|\/)[^/]*\.(p12|pfx|jks|keystore)$/) {
        if (first == "") {
          first = $0
        }
      }
    }
    END {
      if (first != "") {
        print first
      }
    }
  '
}

forbidden_file="$(
  find "${STAGING_DIR}" -type f -printf '%P\n' | is_forbidden_path
)"
if [[ -n "${forbidden_file}" ]]; then
  echo "External credential file must not be embedded in the Debian package: ${forbidden_file#${STAGING_DIR}/}" >&2
  exit 1
fi

secret_template="${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/templates/${RELEASE_PROJECT_NAME}.secrets.env"
if [[ ! -f "${secret_template}" ]]; then
  echo "Package credential template is missing." >&2
  exit 1
fi
if ! awk -F= '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  {
    key = $1
    value = substr($0, index($0, "=") + 1)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
    external = key ~ /^(FIREBASE|FCM|FACEBOOK|PAYMENT|STRIPE|BARION|PAYPAL|ADYEN|EMAIL|SENDGRID|SMTP|TWILIO|DISCORD|DISCOURSE|COMMUNITY|SOCIAL|OAUTH|OIDC|REMOTE_PROVIDER|PROVIDER)_/
    secret = key ~ /(_API_KEY|_ACCESS_TOKEN|_AUTH_TOKEN|_TOKEN|_CLIENT_SECRET|_APP_SECRET|_SECRET|_PASSWORD|_PRIVATE_KEY|_CREDENTIALS?|_WEBHOOK_SECRET|_SIGNING_SECRET)$/
    generated_internal = key ~ /^(MONGO_INITDB_ROOT_PASSWORD|MONGO_APP_PASSWORD|MINIO_ROOT_PASSWORD)$/
    generated_bootstrap = key ~ /^OPERATOR_BOOTSTRAP_(EMAIL|PASSWORD_SHA256)$/
    if (external \
        && secret \
        && value != "" \
        && value !~ /^replace-with-/) {
      print key
      failed = 1
    }
    if (generated_internal && value !~ /^replace-with-/) {
      print key
      failed = 1
    }
    if (generated_bootstrap && value != "") {
      print key
      failed = 1
    }
  }
  END { exit failed }
' "${secret_template}"; then
  echo "Provider credentials must be empty and internal passwords must remain generated placeholders in the package template." >&2
  exit 1
fi

consumer_email_pattern="$(release_config_value .audit.consumerEmailPattern)"
personal_social_pattern="$(release_config_value .audit.personalSocialPattern)"
personal_identifier_file="$(
  grep -RIl \
    --exclude='*.tar' \
    -E -i -- "${consumer_email_pattern}" \
    "${STAGING_DIR}" \
    2>/dev/null \
    | head -n 1 \
    || true
)"
if [[ -n "${personal_identifier_file}" ]]; then
  echo "Personal deployment email must not be embedded in the Debian package: ${personal_identifier_file#${STAGING_DIR}/}" >&2
  exit 1
fi
personal_social_file=""
while IFS= read -r candidate_file; do
  if (
    set +o pipefail
    sed -f "${AUDIT_TMP}/social-text.sed" \
      "${candidate_file}" \
      | grep -Eiq -- "${personal_social_pattern}"
  ); then
    personal_social_file="${candidate_file}"
    break
  fi
done < <(
  grep -RIl \
    --exclude='*.tar' \
    -E -i -- "${personal_social_pattern}" \
    "${STAGING_DIR}" \
    2>/dev/null \
    || true
)
if [[ -n "${personal_social_file}" ]]; then
  echo "Personal social-page URL must not be embedded in the Debian package: ${personal_social_file#${STAGING_DIR}/}" >&2
  exit 1
fi

audit_mongo_seed_privacy() {
  local seed_root production_seed demo_seed packaged_env seed_rule
  local actual_collections expected_collections

  seed_root="${STAGING_DIR}${RELEASE_PROJECT_ROOT}/server/docker/conf/mongodb"
  [[ -d "${seed_root}" ]] || return 0
  production_seed="${seed_root}/$(release_config_value .mongo.productionSeedDirectory)"
  demo_seed="${seed_root}/$(release_config_value .mongo.demoSeedDirectory)"
  packaged_env="${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/templates/${RELEASE_PROJECT_NAME}.env"

  if [[ -d "${seed_root}/$(release_config_value .mongo.testSeedDirectory)" ]]; then
    echo "E2E Mongo fixtures must not be embedded in the production package." >&2
    exit 1
  fi
  if [[ ! -d "${production_seed}" || ! -d "${demo_seed}" ]]; then
    echo "Production and isolated Explore Mongo seed directories are required." >&2
    exit 1
  fi

  seed_rule="$(
    sed -n 's/^MONGO_IMPORT_ALLOWED_COLLECTIONS_BY_DB=//p' "${packaged_env}" \
      | tr ';' '\n' \
      | sed -n "s/^$(release_config_value .mongo.productionDatabase)://p" \
      | tail -n 1
  )"
  if [[ -z "${seed_rule}" || "${seed_rule}" == *"*"* ]]; then
    echo "Packaged production Mongo seed allow-list must be explicit." >&2
    exit 1
  fi
  expected_collections="$(
    tr ',' '\n' <<< "${seed_rule}" \
      | sed '/^[[:space:]]*$/d; s/$/.json/' \
      | sort
  )"
  actual_collections="$(
    find "${production_seed}" -maxdepth 1 -type f -name '*.json' \
      -printf '%f\n' \
      | sort
  )"
  if [[ "${actual_collections}" != "${expected_collections}" ]]; then
    echo "Packaged production Mongo seeds do not match the explicit system/configuration allow-list." >&2
    exit 1
  fi

  if ! jq -e '
      type == "array"
      and all(.[];
        ((.adminEmails // []) | type == "array")
        and ((.adminEmails // []) | length == 0))
    ' "${production_seed}/appSettings.json" >/dev/null; then
    echo "Production app settings nominate a packaged administrator." >&2
    exit 1
  fi
  local -a forbidden_patterns=()
  while IFS= read -r collection; do
    forbidden_patterns+=(-name "${collection}.json" -o)
  done < <(release_config_value '.audit.forbiddenProductionCollections[]')
  if (( ${#forbidden_patterns[@]} > 0 )) && find "${production_seed}" -maxdepth 1 -type f \
      \( "${forbidden_patterns[@]:0:${#forbidden_patterns[@]}-1}" \) -print -quit \
      | grep -q .; then
    echo "A private/runtime collection was embedded in the production Mongo seed." >&2
    exit 1
  fi
  # Product-owned public pages have been intentional defaults since MSC-115.
  # Remove only those exact JSON string values; suffixes and other URLs remain
  # subject to the deployment-specific social-link rejection below.
  if find "${production_seed}" -maxdepth 1 -type f -name '*.json' -print0 \
      | xargs -0 cat \
      | sed -f "${AUDIT_TMP}/social-seeds.sed" \
      | grep -Ei -- "$(release_config_value .audit.productionSocialPattern)" >/dev/null; then
    echo "A deployment-specific social-page URL was embedded in the production Mongo seed." >&2
    exit 1
  fi

  if ! jq -e --slurpfile policy "${AUDIT_TMP}/release-settings.json" '
      type == "array"
      and length == 1
      and .[0]._id == $policy[0].audit.deploymentConfiguration.id
      and .[0].schemaVersion == $policy[0].audit.deploymentConfiguration.schemaVersion
      and (.[0].privacyContact | type == "object")
      and .[0].privacyContact.dataControllerName == ""
      and .[0].privacyContact.privacyContactEmail == ""
      and (.[0].integration | type == "object")
      and .[0].integration.publicBaseUrl == null
    ' "${production_seed}/deploymentConfigurations.json" >/dev/null; then
    echo "Production deployment configuration must be schema v5 with privacy and Integration URL unconfigured." >&2
    exit 1
  fi
  audit_project_seeds "${production_seed}" "${REPO_ROOT}"

  if ! jq -e '
      type == "array"
      and any(.[];
        .settingsKey == "global"
        and ((.adminEmails // []) | length > 0))
      and all(.[];
        all((.adminEmails // [])[];
          test("@[^@]+\\.(local|invalid)$"; "i")))
    ' "${demo_seed}/appSettings.json" >/dev/null; then
    echo "Explore administrator identities must be explicit synthetic .local/.invalid addresses." >&2
    exit 1
  fi
}

audit_mongo_seed_privacy

audit_image_archive() {
  local archive="$1"
  local archive_label manifest config layer layer_file offending nested_member
  local application_member application_member_file
  local -a configs=()
  local -a layers=()
  local -a nested_members=()
  local -a application_members=()

  archive_label="${archive#${STAGING_DIR}/}"
  manifest="${AUDIT_TMP}/manifest.json"
  if ! tar -xOf "${archive}" manifest.json > "${manifest}" 2>/dev/null \
    || ! jq -e '
      type == "array"
      and length > 0
      and all(.[];
        (.Config | type == "string")
        and (.Layers | type == "array")
        and all(.Layers[]; type == "string"))
    ' "${manifest}" >/dev/null; then
    echo "Bundled managed image archive is invalid: ${archive_label}" >&2
    exit 1
  fi

  mapfile -t configs < <(jq -r '.[].Config' "${manifest}" | sort -u)
  mapfile -t layers < <(jq -r '.[].Layers[]' "${manifest}" | sort -u)

  for config in "${configs[@]}"; do
    if ! tar -xOf "${archive}" "${config}" > "${AUDIT_TMP}/config.json" 2>/dev/null \
      || ! jq -e --slurpfile policy "${AUDIT_TMP}/release-settings.json" '
        def external:
          test("^(FIREBASE|FCM|FACEBOOK|PAYMENT|STRIPE|BARION|PAYPAL|ADYEN|EMAIL|SENDGRID|SMTP|TWILIO|DISCORD|DISCOURSE|COMMUNITY|SOCIAL|OAUTH|OIDC|REMOTE_PROVIDER|PROVIDER)_");
        def secret:
          test("(_API_KEY|_ACCESS_TOKEN|_AUTH_TOKEN|_TOKEN|_CLIENT_SECRET|_APP_SECRET|_SECRET|_PASSWORD|_PRIVATE_KEY|_CREDENTIALS?|_WEBHOOK_SECRET|_SIGNING_SECRET)$");
        def consumerEmail:
          test($policy[0].audit.imageConsumerEmailPattern; "i");
        def personalSocial:
          test($policy[0].audit.imagePersonalSocialPattern; "i");
        [
          (.config.Env // [])[]?
          | capture("^(?<key>[^=]+)=(?<value>.*)$")
          | select(
              ((.key | external) and (.key | secret))
              or (.key | test("^(MONGO_INITDB_ROOT_PASSWORD|MONGO_APP_PASSWORD|MINIO_ROOT_PASSWORD)$"))
              or (.key | test("^OPERATOR_BOOTSTRAP_(EMAIL|PASSWORD_SHA256)$"))
              or (.value | consumerEmail)
              or (.value | personalSocial))
          | select(.value != "" and (.value | startswith("replace-with-") | not))
        ] | length == 0
      ' "${AUDIT_TMP}/config.json" >/dev/null; then
      echo "Credential or personal deployment identifier found in managed image configuration: ${archive_label}" >&2
      exit 1
    fi
  done

  for layer in "${layers[@]}"; do
    layer_file="${AUDIT_TMP}/layer.tar"
    if ! tar -xOf "${archive}" "${layer}" > "${layer_file}" 2>/dev/null \
      || ! tar -tf "${layer_file}" >/dev/null 2>&1; then
      echo "Bundled managed image layer is invalid: ${archive_label}" >&2
      exit 1
    fi

    offending="$(tar -tf "${layer_file}" | is_forbidden_path)"
    if [[ -n "${offending}" ]]; then
      echo "External credential file found in managed image ${archive_label}: ${offending}" >&2
      exit 1
    fi
    private_key_status=0
    python3 "${PRIVATE_KEY_AUDIT}" "${layer_file}" >/dev/null 2>&1 \
      || private_key_status=$?
    if [[ "${private_key_status}" -eq 0 ]]; then
      echo "Private key material found in managed image: ${archive_label}" >&2
      exit 1
    fi
    if [[ "${private_key_status}" -ne 1 ]]; then
      echo "Private-key audit failed for managed image: ${archive_label}" >&2
      exit 1
    fi
    mapfile -t application_members < <(
      tar -tf "${layer_file}" \
        | awk '
          {
            path = tolower($0)
            sub(/^\.\//, "", path)
            if (path ~ /^usr\/share\/nginx\/html\/.*\.(html|js|json|map)$/ \
                && path !~ /(^|\/)(3rdpartylicenses|licenses?)(\.|\/|$)/) {
              print $0
            }
          }
        '
    )
    for application_member in "${application_members[@]}"; do
      application_member_file="${AUDIT_TMP}/application-member"
      if ! tar -xOf "${layer_file}" "${application_member}" \
          > "${application_member_file}" 2>/dev/null; then
        echo "Managed frontend image member could not be audited: ${archive_label}" >&2
        exit 1
      fi
      if grep -aEiq -- "${consumer_email_pattern}" \
          "${application_member_file}"; then
        echo "Personal deployment email found in managed frontend application content: ${archive_label}" >&2
        exit 1
      fi
    done
    if (
      set +o pipefail
      sed -f "${AUDIT_TMP}/social-text.sed" \
        "${layer_file}" 2>/dev/null \
        | grep -aEiq -- "${personal_social_pattern}"
    ); then
      echo "Personal social-page URL found in managed image: ${archive_label}" >&2
      exit 1
    fi
    if grep -aEiq \
      -- 'operator[-_]bootstrap[-_]password[-_]sha256[=:][[:space:]]*[0-9a-f]{64}' \
      "${layer_file}"; then
      echo "Fixed Operator bootstrap password digest found in managed image: ${archive_label}" >&2
      exit 1
    fi
    if grep -aEiq \
      -- 'operator[-_]bootstrap[-_]email[=:][[:space:]]*operator-[0-9a-f]{24}@deployment\.invalid' \
      "${layer_file}"; then
      echo "Fixed Operator bootstrap subject found in managed image: ${archive_label}" >&2
      exit 1
    fi

    mapfile -t nested_members < <(
      tar -tf "${layer_file}" \
        | awk 'tolower($0) ~ /\.(jar|war|zip)$/ { print }'
    )
    for nested_member in "${nested_members[@]}"; do
      if ! tar -xOf "${layer_file}" "${nested_member}" \
          > "${AUDIT_TMP}/nested-archive" 2>/dev/null \
        || ! python3 "${NESTED_ARCHIVE_AUDIT}" \
          "${AUDIT_TMP}/nested-archive" "${AUDIT_TMP}/release-settings.json" >/dev/null; then
        echo "Credential audit failed for nested managed-image archive: ${archive_label}" >&2
        exit 1
      fi
    done
    rm -f "${layer_file}"
  done
}

while IFS= read -r image_archive; do
  audit_image_archive "${image_archive}"
done < <(
  find "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/images" \
    -maxdepth 1 -type f -name '*.tar' -print 2>/dev/null \
    | sort
)

offending_file=""
while IFS= read -r candidate_file; do
  private_key_status=0
  python3 "${PRIVATE_KEY_AUDIT}" "${candidate_file}" >/dev/null 2>&1 \
    || private_key_status=$?
  if [[ "${private_key_status}" -eq 0 ]]; then
    offending_file="${candidate_file}"
    break
  fi
  if [[ "${private_key_status}" -ne 1 ]]; then
    echo "Private-key audit could not inspect: ${candidate_file#${STAGING_DIR}/}" >&2
    exit 1
  fi
done < <(
  find "${STAGING_DIR}" -type f \
    ! -name '*.example' \
    ! -name '*.tar' \
    ! -name 'audit-package-credentials.sh' \
    ! -name 'audit-nested-archive.py' \
    ! -name 'private_key_material.py' \
    -print
)
if [[ -n "${offending_file}" ]]; then
  echo "Private key material must not be embedded in the Debian package: ${offending_file#${STAGING_DIR}/}" >&2
  exit 1
fi
