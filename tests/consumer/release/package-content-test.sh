#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}"
export MYSCOUTEE_PACKAGING_PROJECT_ROOT="$REPO_ROOT"
PACKAGE_SCRIPT="${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/package-production.sh"
CREDENTIAL_AUDIT="${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/audit/audit-package-credentials.sh"
TEST_ROOT="$(mktemp -d /tmp/myscoutee-package-content-test.XXXXXX)"

cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT
mkdir -p "${TEST_ROOT}/debian"
python3 "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py" "${REPO_ROOT}/packaging" "${TEST_ROOT}/debian" --hook all

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

for command_name in dpkg-deb jq node python3 rsync tar; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "required test command is missing: ${command_name}"
done

for verifier_source in \
  README.md \
  browser-smoke.mjs \
  run.mjs \
  checks.mjs \
  lib/assertions.mjs \
  lib/http.mjs; do
  [[ -f "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/verification/public/${verifier_source}" ]] \
    || fail "deployment verifier source is missing: ${verifier_source}"
done
[[ ! -e "${REPO_ROOT}/smoke" && ! -e "${REPO_ROOT}/packaging/smoke" ]] \
  || fail "deployment verifier still has an ambiguous smoke source path"

node "${REPO_ROOT}/tests/packaging/deployment/mobile-qa-isolation-test.mjs" >/dev/null \
  || fail "development/QA production isolation regression"

bash "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/consumer/debian/numeric-ownership-policy-test.sh" >/dev/null \
  || fail "numeric host ownership policy regression"
bash "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/consumer/debian/debian-removal-contract-test.sh" >/dev/null \
  || fail "Debian lifecycle deleted retained deployment state"
bash "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/consumer/debian/debian-tls-lifecycle-test.sh" >/dev/null \
  || fail "Debian lifecycle replaced retained operator TLS material"
bash "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/unit/update-worker-test.sh" >/dev/null \
  || fail "signed update lifecycle or data-preservation contract regression"
python3 "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/unit/update-status-server-test.py" >/dev/null \
  || fail "independent update progress authorization or status regression"
bash "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/consumer/runtime/restart-update-stack-test.sh" >/dev/null \
  || fail "update restart did not preserve progress ingress"
bash "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/consumer/runtime/demo-reset-test.sh" >/dev/null \
  || fail "demo reset lifecycle or production boundary regression"
bash "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/consumer/mongo/mongo-import-entrypoint-test.sh" >/dev/null \
  || fail "Mongo initialization hook terminated its parent entrypoint"
bash "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/consumer/runtime/i18n-runtime-seed-sync-test.sh" >/dev/null \
  || fail "production i18n runtime seed synchronization regression"
bash "${REPO_ROOT}/server/docker/images/mongodb-sync/dev/mongodb-seed-sync-test.sh" >/dev/null \
  || fail "Mongo seed watcher lost a file update during import"
node "${REPO_ROOT}/config/packaging/seeds/scripts/normalize-chat-seed.mjs" >/dev/null \
  || fail "demo chat seed membership or message-summary regression"

FRONTEND_SYNC_ROOT="${TEST_ROOT}/frontend-sync"
FRONTEND_SYNC_TARGET="${TEST_ROOT}/nginx-html"
install -d \
  "${FRONTEND_SYNC_ROOT}/prod" \
  "${FRONTEND_SYNC_ROOT}/docs" \
  "${FRONTEND_SYNC_TARGET}"
printf '%s\n' 'production-build' \
  > "${FRONTEND_SYNC_ROOT}/prod/build-source.txt"
printf '%s\n' 'github-build' \
  > "${FRONTEND_SYNC_ROOT}/docs/build-source.txt"
FRONTEND_ROOT="${FRONTEND_SYNC_ROOT}" \
NGINX_HTML_DIR="${FRONTEND_SYNC_TARGET}" \
  bash "${REPO_ROOT}/server/docker/scripts/sync_frontend_assets.sh" prod \
  >/dev/null
grep -Fxq 'production-build' \
  "${FRONTEND_SYNC_TARGET}/build-source.txt" \
  || fail "production Nginx sync did not use the production Angular output"
if grep -Fqx 'github-build' \
    "${FRONTEND_SYNC_TARGET}/build-source.txt"; then
  fail "production Nginx sync copied the GitHub Pages output"
fi

for production_identity_seed in \
  "${REPO_ROOT}/server/docker/conf/mongodb/myscoutee_db/adminUsers.json" \
  "${REPO_ROOT}/server/docker/conf/mongodb/myscoutee_db/users.json"; do
  jq -e 'type == "array" and length == 0' \
    "${production_identity_seed}" >/dev/null \
    || fail "production identity source seed is not empty: ${production_identity_seed#${REPO_ROOT}/}"
done

assert_admin_job_seed_defaults() {
  local seed_file="$1"

  jq -e '
    [
      "event-random-groups",
      "event-auto-inviter",
      "event-tournament-review",
      "event-counter-expiry",
      "event-checkout-basket-purge",
      "notification-outbox",
      "payment-method-expiry",
      "affinity-recompute",
      "affinity-graph-layout",
      "scheduled-messages",
      "account-purge",
      "content-auto-approve",
      "account-deletion-warning",
      "payment-exchange-rates",
      "event-mingle-advance",
      "event-watchlist",
      "event-cancellation",
      "affiliate-revenue",
      "integration-encounters",
      "integration-webhooks",
      "promotional-email-planning",
      "promotional-email-delivery",
      "admin-telemetry",
      "affinity-admin-signals",
      "events-admin-signals",
      "notifications-admin-signals",
      "media-deletion"
    ] as $expected
    | ($expected - ["event-random-groups"]) as $groupExpected
    | type == "array"
    and ([.[] | ._id] | length == (unique | length))
    and ([.[] | [(.baseGroupId // ""), .ruleKey]] | length == (unique | length))
    and ((map(.baseGroupId // "") | unique | sort)
      == ["", "myscoutee-community", "myscoutee-work"])
    and ((map(select((.baseGroupId // "") == "") | .ruleKey) | sort) == ($expected | sort))
    and ((map(select(.baseGroupId == "myscoutee-work") | .ruleKey) | sort) == ($groupExpected | sort))
    and ((map(select(.baseGroupId == "myscoutee-community") | .ruleKey) | sort)
      == (($groupExpected + ["community-scheduled-cases", "community-voting-close"]) | sort))
    and all(.[];
      .enabled == true
      and .triggerKind == "scheduled_process"
      and (
        if .ruleKey == "event-random-groups" or .ruleKey == "payment-exchange-rates" or .ruleKey == "media-deletion"
        then .manualRunEnabled == true
        else .manualRunEnabled == false
        end
      ))
  ' "${seed_file}" >/dev/null \
    || fail "Admin Job defaults are invalid: ${seed_file#${REPO_ROOT}/}"
}

for admin_job_seed in \
  "${REPO_ROOT}/server/docker/conf/mongodb/myscoutee_db/notificationRuleConfigs.json" \
  "${REPO_ROOT}/server/docker/conf/mongodb/demo_db/notificationRuleConfigs.json" \
  "${REPO_ROOT}/server/docker/conf/mongodb/e2e_db/notificationRuleConfigs.json"; do
  assert_admin_job_seed_defaults "${admin_job_seed}"
done

assert_dockerignore_line() {
  local dockerignore="$1"
  local pattern="$2"

  grep -Fxq -- "${pattern}" "${dockerignore}" \
    || fail "${dockerignore#${REPO_ROOT}/} does not exclude ${pattern}"
}

assert_no_development_scripts_mount() {
  local compose_file="$1"

  [[ -f "${compose_file}" ]] \
    || fail "production Compose file is missing: ${compose_file#${REPO_ROOT}/}"
  if sed -E 's/[[:space:]]+#.*$//' "${compose_file}" \
      | grep -Eq "^[[:space:]]*(-[[:space:]]+|source:[[:space:]]+).*docker/scripts([/:]|[\"']?[[:space:]]*$)"; then
    fail "${compose_file#${REPO_ROOT}/} exposes development scripts inside a runtime container"
  fi
}

SERVER_DOCKERIGNORE="${REPO_ROOT}/server/.dockerignore"
NGINX_DOCKERIGNORE="${REPO_ROOT}/server/docker/.dockerignore"
PRODUCTION_COMPOSE="${REPO_ROOT}/server/docker-compose-prod.yml"
PRODUCTION_API_DOCKERFILE="${REPO_ROOT}/server/docker/images/profilemanagement/prod/Dockerfile"
for pattern in \
  '.env' '.env.*' 'projects/profile/secrets/' \
  'docker/scripts/admin-job-fixtures/' 'docker/.qa-mobile-runtime/' \
  'docker/conf/nginx/keys/' 'data/' \
  '**/*.pem' '**/*.key' '**/*.p8' \
  '**/*service-account*.json' '**/*client-secret*.json' \
  '**/*provider-credentials*.json'; do
  assert_dockerignore_line "${SERVER_DOCKERIGNORE}" "${pattern}"
done

grep -Eq '^[[:space:]]+context: projects/profile/build/libs$' "${PRODUCTION_COMPOSE}" \
  || fail "production API build context is not restricted to the compiled JAR directory"
grep -Eq '^[[:space:]]+dockerfile: \.\./\.\./\.\./\.\./docker/images/profilemanagement/prod/Dockerfile$' "${PRODUCTION_COMPOSE}" \
  || fail "production API Dockerfile is not resolved from the restricted JAR context"
grep -Fqx 'COPY --chown=myscoutee:myscoutee profile-${MYSCOUTEE_VERSION}.jar /app/spring-boot-application.jar' "${PRODUCTION_API_DOCKERFILE}" \
  || fail "production API image does not select the exact release JAR from the restricted build context"

for pattern in \
  'conf/nginx/keys/' \
  'scripts/admin-job-fixtures/' '.qa-mobile-runtime/' \
  '**/*.pem' '**/*.key' '**/*.p8' \
  '**/*service-account*.json' '**/*client-secret*.json' \
  '**/*provider-credentials*.json'; do
  assert_dockerignore_line "${NGINX_DOCKERIGNORE}" "${pattern}"
done

for production_compose in \
  "${REPO_ROOT}/server/docker-compose-prod.yml" \
  "${REPO_ROOT}/server/docker-compose.replicaset.yml" \
  "${REPO_ROOT}/config/packaging/compose/docker-compose.production.yml" \
  "${REPO_ROOT}/config/packaging/compose/docker-compose.production-replicaset.yml"; do
  assert_no_development_scripts_mount "${production_compose}"
done

DEB_PATH="$(
  MYSCOUTEE_VERSION=1.0.0 \
  MYSCOUTEE_DIST_DIR="${TEST_ROOT}/dist" \
  BUILD_ARTIFACTS=false \
  PACKAGE_IMAGES=false \
  ALLOW_UNBUNDLED_IMAGES_FOR_TESTS=true \
  bash "${PACKAGE_SCRIPT}" | tail -n 1
)"
[[ -f "${DEB_PATH}" ]] || fail "package-content fixture was not built"
[[ "$(stat -c '%a' "${DEB_PATH}")" == "644" ]] \
  || fail "Debian release artifact is not mode 0644"

CONTENTS="${TEST_ROOT}/contents.txt"
dpkg-deb --fsys-tarfile "${DEB_PATH}" | tar -tf - > "${CONTENTS}"
if grep -Fxq './opt/myscoutee/server/projects/profile/secrets/firebase-service-account.json' \
  "${CONTENTS}"; then
  fail "real Firebase service-account JSON was embedded in the package"
fi
if grep -Eq '/(admin-job-fixtures|manual-qa-checkpoints|\.qa-mobile-runtime)(/|$)|/(start_profilemanagement_dev|frontend_auto_watch)\.sh$' "${CONTENTS}"; then
  fail "development/QA helpers were embedded in the production package"
fi
if grep -Eq '^\./opt/myscoutee/packaging/release(/|$)' "${CONTENTS}"; then
  fail "source-only release tools were embedded in the production package"
fi
for source_only_helper in \
  audit-nested-archive.py \
  audit-package-credentials.sh \
  build-debian-release.sh \
  build-production.sh \
  package-production.sh \
  private_key_material.py \
  qualify-release-artifacts.sh \
  rebuild-production-services.sh \
  sign-release-artifacts.sh \
  purge-local-datastores.sh; do
  if grep -Eq "/${source_only_helper}$" "${CONTENTS}"; then
    fail "source-only helper was embedded in the production package: ${source_only_helper}"
  fi
done
if grep -Eiq \
  '/(\.env\.secrets|application-secrets\.ya?ml|[^/]*(client-secret|provider-credentials)[^/]*\.json|[^/]*\.(p12|pfx|jks|keystore))$' \
  "${CONTENTS}"; then
  fail "an external provider credential container was embedded in the package"
fi
grep -Fxq \
  './opt/myscoutee/server/projects/profile/secrets/firebase-service-account.json.example' \
  "${CONTENTS}" \
  || fail "Firebase provisioning example is missing"
grep -Fxq './opt/myscoutee/packaging/scripts/myscoutee-safe-copy.py' \
  "${CONTENTS}" \
  || fail "safe-copy helper is missing"
grep -Fxq \
  './opt/myscoutee/packaging/scripts/ensure-operator-configuration-key.sh' \
  "${CONTENTS}" \
  || fail "operator configuration key initializer is missing"
grep -Fxq \
  './opt/myscoutee/packaging/scripts/image-content-fingerprint.sh' \
  "${CONTENTS}" \
  || fail "portable managed-image fingerprint helper is missing"
if grep -Fxq './etc/myscoutee/configuration/deployment-master-key' \
  "${CONTENTS}"; then
  fail "operator configuration master key was embedded in the package"
fi
if grep -Eq \
  '/(deployment-private-key\.pem|deployment-public-key\.der|registry-demo-signing-key\.pem)$' \
  "${CONTENTS}"; then
  fail "a node or demo-registry identity key was embedded in the package"
fi
grep -Fxq './lib/systemd/system/myscoutee-update.service' "${CONTENTS}" \
  || fail "update service is missing"
grep -Fxq './lib/systemd/system/myscoutee-update.path' "${CONTENTS}" \
  || fail "update path unit is missing"
for tls_unit in \
  myscoutee-tls.path \
  myscoutee-tls.service \
  myscoutee-tls-renew.service \
  myscoutee-tls-renew.timer; do
  grep -Fxq "./lib/systemd/system/${tls_unit}" "${CONTENTS}" \
    || fail "TLS unit ${tls_unit} is missing"
done
grep -Fxq \
  './opt/myscoutee/packaging/scripts/myscoutee-tls-worker.sh' \
  "${CONTENTS}" \
  || fail "privileged TLS worker is missing"
for host_helper in \
  qualify-deployment.sh \
  deployment-diagnostics.sh; do
  grep -Fxq "./opt/myscoutee/packaging/scripts/${host_helper}" \
    "${CONTENTS}" \
    || fail "installed host qualification helper is missing: ${host_helper}"
done
EMBEDDED_CLIENT_TOOLS_PATH='./usr/share/myscoutee/myscoutee-client-tools_1.0.0.tar.gz'
grep -Fxq "${EMBEDDED_CLIENT_TOOLS_PATH}" "${CONTENTS}" \
  || fail "versioned Operator client-tools archive is missing from the package"
if grep -Eq '^\./usr/share/myscoutee/client-tools(/|$)' "${CONTENTS}"; then
  fail "the deployment package contains a redundant client-tools directory"
fi
grep -Fxq './opt/myscoutee/packaging/IMAGE-MANIFEST.json' "${CONTENTS}" \
  || fail "package image manifest is missing"

EXTRACTED="${TEST_ROOT}/extracted"
CONTROL_EXTRACTED="${TEST_ROOT}/control"
dpkg-deb -x "${DEB_PATH}" "${EXTRACTED}"
dpkg-deb -e "${DEB_PATH}" "${CONTROL_EXTRACTED}"
python3 "${EXTRACTED}/opt/myscoutee/packaging/scripts/migrate-seeded-media.py" check-inputs \
  "${EXTRACTED}/opt/myscoutee/packaging/migrations/seeds/023-seeded-image-webp/image-replacements.json" \
  "${EXTRACTED}/opt/myscoutee/server/docker/conf/minio/media"

for migration_input in \
  008-default-help-v3.js \
  013-default-help-v5.js \
  seeds/008-default-help-v3/helpCenterRevisions.json \
  seeds/013-default-help-v5/helpCenterRevisions.json; do
  cmp "${REPO_ROOT}/config/packaging/migrations/${migration_input}" \
    "${EXTRACTED}/opt/myscoutee/packaging/migrations/${migration_input}" \
    || fail "packaged help migration input differs: ${migration_input}"
done
[[ -x "${EXTRACTED}/opt/myscoutee/packaging/scripts/image-content-fingerprint.sh" ]] \
  || fail "portable managed-image fingerprint helper is not executable"
CLIENT_TOOLS_ARCHIVE="${TEST_ROOT}/dist/myscoutee-client-tools_1.0.0.tar.gz"
[[ -s "${CLIENT_TOOLS_ARCHIVE}" ]] \
  || fail "standalone Operator client-tools archive is missing"
[[ "$(stat -c '%a' "${CLIENT_TOOLS_ARCHIVE}")" == "644" ]] \
  || fail "standalone Operator client-tools archive is not mode 0644"
EMBEDDED_CLIENT_TOOLS_ARCHIVE="${EXTRACTED}/${EMBEDDED_CLIENT_TOOLS_PATH#./}"
[[ "$(stat -c '%a' "${EMBEDDED_CLIENT_TOOLS_ARCHIVE}")" == "644" ]] \
  || fail "embedded Operator client-tools archive is not mode 0644"
cmp -s "${CLIENT_TOOLS_ARCHIVE}" "${EMBEDDED_CLIENT_TOOLS_ARCHIVE}" \
  || fail "embedded and standalone Operator client-tools archives differ"
CLIENT_TOOLS_CONTENTS="${TEST_ROOT}/client-tools-contents.txt"
tar -tzf "${EMBEDDED_CLIENT_TOOLS_ARCHIVE}" > "${CLIENT_TOOLS_CONTENTS}"
for verifier_member in \
  README.md \
  browser-smoke.mjs \
  run.mjs \
  checks.mjs \
  lib/assertions.mjs \
  lib/http.mjs; do
  grep -Fxq "./verify-deployment/${verifier_member}" \
    "${CLIENT_TOOLS_CONTENTS}" \
    || fail "standalone Operator archive omits deployment verifier member ${verifier_member}"
done
grep -Fxq './install.env.example' "${CLIENT_TOOLS_CONTENTS}" \
  || fail "standalone Operator archive omits safe configuration example"
grep -Fxq './prepare-debian13-minimal.sh' "${CLIENT_TOOLS_CONTENTS}" \
  || fail "standalone Operator archive omits Debian 13 host preparation"
tar -xOzf "${CLIENT_TOOLS_ARCHIVE}" ./prepare-debian13-minimal.sh \
  | cmp - "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/client-tools/prepare-debian13-minimal.sh" \
  || fail "archived Debian 13 preparation differs from its source"
if grep -Fxq './install.env' "${CLIENT_TOOLS_CONTENTS}"; then
  fail "local Operator target credentials were embedded in the client-tools archive"
fi
jq -e \
  '.schemaVersion == 1
    and .releaseVersion == "1.0.0"
    and .bundled == false
    and .images == []' \
  "${EXTRACTED}/opt/myscoutee/packaging/IMAGE-MANIFEST.json" >/dev/null \
  || fail "test-only unbundled manifest is invalid"

PACKAGED_MONGO="${EXTRACTED}/opt/myscoutee/server/docker/conf/mongodb"
PACKAGED_PRODUCTION_SEED="${PACKAGED_MONGO}/myscoutee_db"
PACKAGED_DEMO_SEED="${PACKAGED_MONGO}/demo_db"
PACKAGED_DEMO_RESET="${EXTRACTED}/opt/myscoutee/packaging/scripts/reset-demo-state.sh"
PACKAGED_I18N_SYNC="${EXTRACTED}/opt/myscoutee/packaging/scripts/sync-i18n-seeds.sh"
[[ -x "${PACKAGED_DEMO_RESET}" && ! -L "${PACKAGED_DEMO_RESET}" ]] \
  || fail "packaged demo reset helper is missing or not executable"
[[ -x "${PACKAGED_I18N_SYNC}" && ! -L "${PACKAGED_I18N_SYNC}" ]] \
  || fail "production i18n runtime seed synchronizer is missing or not executable"
grep -Fxq \
  'ExecStartPre=/opt/myscoutee/packaging/scripts/reset-demo-state.sh' \
  "${EXTRACTED}/lib/systemd/system/myscoutee.service" \
  || fail "systemd does not reset disposable Explore state before start"
grep -Fxq \
  'ExecStartPre=/opt/myscoutee/packaging/scripts/sync-i18n-seeds.sh --prepare-only' \
  "${EXTRACTED}/lib/systemd/system/myscoutee.service" \
  || fail "production service does not synchronize the authoritative backend bundle before start"
grep -Fq \
  'systemctl is-active --quiet ${PACKAGE_NAME}.service' \
  "${CONTROL_EXTRACTED}/postinst" \
  || fail "an active deployment upgrade does not detect the running service"
grep -Fq \
  '${PACKAGE_ROOT}/packaging/scripts/sync-i18n-seeds.sh' \
  "${CONTROL_EXTRACTED}/postinst" \
  || fail "an active deployment upgrade does not synchronize the backend bundle"
assert_admin_job_seed_defaults "${PACKAGED_PRODUCTION_SEED}/notificationRuleConfigs.json"
assert_admin_job_seed_defaults "${PACKAGED_DEMO_SEED}/notificationRuleConfigs.json"
[[ ! -e "${PACKAGED_MONGO}/e2e_db" ]] \
  || fail "E2E Mongo fixtures were embedded in the production package"
for forbidden_seed in \
  users adminUsers userRates userFilterPreferences navigatorContacts \
  activityMembers activityResources assets assetRequests events chats \
  chatMessages payments; do
  [[ ! -e "${PACKAGED_PRODUCTION_SEED}/${forbidden_seed}.json" ]] \
    || fail "private/runtime production seed was embedded: ${forbidden_seed}"
done
jq -e 'type == "array" and length > 0 and all(.[]; .screenKey and .id)' \
  "${PACKAGED_PRODUCTION_SEED}/helpCenterGuideFields.json" >/dev/null \
  || fail "guide migrations require the packaged production field catalog"
jq -e '
  type == "array"
  and all(.[];
    ((.adminEmails // []) | type == "array")
    and ((.adminEmails // []) | length == 0))
' "${PACKAGED_PRODUCTION_SEED}/appSettings.json" >/dev/null \
  || fail "production app settings contain a packaged administrator"
jq -e '
  type == "array"
  and length == 1
  and .[0]._id == "deployment-configuration"
  and .[0].schemaVersion == 5
  and .[0].privacyContact.dataControllerName == ""
  and .[0].privacyContact.privacyContactEmail == ""
  and .[0].integration.publicBaseUrl == null
' "${PACKAGED_PRODUCTION_SEED}/deploymentConfigurations.json" >/dev/null \
  || fail "production deployment configuration is not schema v5 with privacy and Integration URL empty"
jq -e '
  [
    .[]
    | select(.documentType == "privacy" and .active == true)
      ] as $documents
  | ($documents | map(.lang) | sort) == ["de", "en", "es", "hu"]
  and all($documents[];
    ([.sections[] | select(.id == "contact-details")] | length == 1)
    and (
      [.sections[] | select(.id == "contact-details")][0].contentHtml
      == "{{deployment.privacy.contactDetails}}"
    )
    and ([.sections[] | select(.id == "account-data-deletion")] | length == 1)
    and (
      [.sections[] | select(.id == "account-data-deletion")][0].contentHtml
      | contains("{{deployment.privacy.deletionEmailRoute}}")
    )
    and (
      [.sections[] | .contentHtml // ""] | join(" ")
      | test("DPO|privacy@myscoutee|myscoutee1@gmail"; "i")
      | not
    ))
' "${PACKAGED_PRODUCTION_SEED}/helpCenterRevisions.json" >/dev/null \
  || fail "production privacy help seed contains fixed contact data or misses runtime tokens"
jq -e '
  type == "array"
  and any(.[];
    .settingsKey == "global"
    and ((.adminEmails // []) | length > 0))
  and all(.[];
    all((.adminEmails // [])[];
      test("@[^@]+\\.(local|invalid)$"; "i")))
' "${PACKAGED_DEMO_SEED}/appSettings.json" >/dev/null \
  || fail "Explore app settings do not use isolated synthetic administrators"
jq -e 'length == 2 and all(.[]; .configured == false)' \
  "${PACKAGED_PRODUCTION_SEED}/communityProviders.json" >/dev/null \
  || fail "production built-in community catalog is missing or preconfigured"
# Apply the same exact public product-page exceptions as the release auditor.
if find "${PACKAGED_PRODUCTION_SEED}" -maxdepth 1 -type f -name '*.json' -print0 \
    | xargs -0 cat \
    | sed -e 's#"https://www\.instagram\.com/myscoutee"#""#g' \
          -e 's#"https://www\.facebook\.com/myscoutee"#""#g' \
          -e 's#"https://www\.youtube\.com/@myscoutee"#""#g' \
    | grep -Ei -- 'https?://([^/"[:space:]]+\.)?(facebook\.com|instagram\.com|linkedin\.com|x\.com|twitter\.com|tiktok\.com|youtube\.com|discord\.(com|gg)|discourse\.[^/"[:space:]]+)/[^/"[:space:]][^"[:space:]]*' >/dev/null; then
  fail "a deployment-specific social-page URL was embedded in the production seed"
fi
consumer_email_pattern='[[:alnum:]._%+-]+@(gmail\.com|googlemail\.com|outlook\.com|hotmail\.com|live\.com|yahoo\.[[:alpha:].]+|icloud\.com|me\.com|proton(mail)?\.com)'
personal_social_pattern='https?://([^/"[:space:]]+\.)?(instagram\.com/[^/"[:space:]][^"[:space:]]*|facebook\.com/[^/"[:space:]][^"[:space:]]*|youtube\.com/(@|channel/|c/|user/)[^/"[:space:]][^"[:space:]]*)'
if grep -RIl \
    --exclude='*.tar' \
    -E -i -- "${consumer_email_pattern}" \
    "${EXTRACTED}" \
    | grep -q .; then
  fail "a personal deployment email was embedded in the package"
fi
while IFS= read -r candidate_file; do
  if (
    set +o pipefail
    sed \
      -e 's#https://www\.instagram\.com/myscoutee##gI' \
      -e 's#https://www\.facebook\.com/myscoutee##gI' \
      -e 's#https://www\.youtube\.com/@myscoutee##gI' \
      -e 's#https://facebook\.com/username##gI' \
      -e 's#https://instagram\.com/username##gI' \
      -e 's#https://www\.facebook\.com/legal/terms##gI' \
      "${candidate_file}" \
      | grep -Eiq -- "${personal_social_pattern}"
  ); then
    fail "a personal social-page URL was embedded in the package"
  fi
done < <(
  grep -RIl \
    --exclude='*.tar' \
    -E -i -- "${personal_social_pattern}" \
    "${EXTRACTED}" \
    || true
)
PACKAGED_COMPOSE="${EXTRACTED}/opt/myscoutee/server/docker-compose-prod.yml"
PACKAGED_REPLICASET_COMPOSE="${EXTRACTED}/opt/myscoutee/server/docker-compose.replicaset.yml"
PACKAGED_ENV="${EXTRACTED}/opt/myscoutee/packaging/templates/myscoutee.env"
assert_no_development_scripts_mount "${PACKAGED_COMPOSE}"
assert_no_development_scripts_mount "${PACKAGED_REPLICASET_COMPOSE}"
if grep -Eq '^[[:space:]]*(ADMIN_USER|DEV_USER|MEMBER_USER):' "${PACKAGED_COMPOSE}"; then
  fail "production Compose contains a baked administrator/developer identity"
fi
grep -Fxq 'OPERATOR_USER=' \
  "${PACKAGED_ENV}" \
  || fail "runtime operator bootstrap allow-list is not empty in the package"
grep -Fxq 'DOMAIN=localhost' "${PACKAGED_ENV}" \
  || fail "fresh installation does not start on the bootstrap localhost domain"
grep -Fxq 'LETSENCRYPT_ENABLED=false' "${PACKAGED_ENV}" \
  || fail "fresh installation does not select the bootstrap certificate"
grep -Fxq \
  'WEBSOCKET_ALLOWED_ORIGIN_PATTERNS=https://localhost,https://127.0.0.1,http://localhost:8080,http://127.0.0.1:8080' \
  "${PACKAGED_ENV}" \
  || fail "fresh installation does not allow its HTTPS loopback origins"
grep -Fxq 'EMAIL_BASE_URL=https://localhost' "${PACKAGED_ENV}" \
  || fail "fresh installation embeds a public deployment URL before Operator setup"
grep -Fxq 'PAYMENT_SIMULATOR_PUBLIC_BASE_URL=https://localhost' "${PACKAGED_ENV}" \
  || fail "fresh installation does not use the bootstrap origin for simulator pages"
grep -Fxq 'PAYMENT_SIMULATOR_APPLICATION_BASE_URL=https://localhost' "${PACKAGED_ENV}" \
  || fail "fresh installation does not use the bootstrap application origin for demo payments"
grep -Fxq 'PAYMENT_SIMULATOR_VOLUME_NAME=myscoutee-payment-simulator-data-v1' "${PACKAGED_ENV}" \
  || fail "fresh installation omits the persistent simulator volume name"
grep -Fq 'DOMAIN: ${DOMAIN:-localhost}' "${PACKAGED_COMPOSE}" \
  || fail "packaged Nginx does not use the neutral bootstrap domain fallback"
grep -Fq 'EMAIL_BASE_URL: "${EMAIL_BASE_URL:-https://localhost}"' \
  "${PACKAGED_COMPOSE}" \
  || fail "packaged API does not receive the dynamic deployment base URL"
grep -Fq 'PAYMENT_SIMULATOR_ENABLED: "true"' "${PACKAGED_COMPOSE}" \
  || fail "packaged API does not enable the Explore payment simulator"
grep -Fq 'PAYMENT_SIMULATOR_BASE_URL: "http://payment-simulator:18082"' \
  "${PACKAGED_COMPOSE}" \
  || fail "packaged API does not use the private simulator provider endpoint"
grep -Fq 'PAYMENT_SIMULATOR_PUBLIC_BASE_URL: "${PAYMENT_SIMULATOR_PUBLIC_BASE_URL:-https://localhost}"' \
  "${PACKAGED_COMPOSE}" \
  || fail "packaged simulator does not receive the public deployment origin"
grep -Fxq 'PAYMENT_SIMULATOR_IMAGE=myscoutee-payment-simulator:1.0.0-prod' \
  "${PACKAGED_ENV}" \
  || fail "packaged environment omits the versioned payment simulator image"
if awk '
    /^  payment-simulator:/ { in_simulator = 1; next }
    /^  [[:alnum:]_-]+:/ { in_simulator = 0 }
    in_simulator && /^[[:space:]]+ports:/ { found = 1 }
    END { exit !found }
  ' "${PACKAGED_COMPOSE}"; then
  fail "packaged payment simulator unexpectedly publishes a host port"
fi
grep -Fxq 'OPERATOR_BOOTSTRAP_PASSWORD_SHA256=' \
  "${EXTRACTED}/opt/myscoutee/packaging/templates/myscoutee.secrets.env" \
  || fail "package contains a bootstrap password digest instead of an empty placeholder"
grep -Fxq 'OPERATOR_BOOTSTRAP_EMAIL=' \
  "${EXTRACTED}/opt/myscoutee/packaging/templates/myscoutee.secrets.env" \
  || fail "package contains a bootstrap subject instead of an empty placeholder"

[[ -x "${EXTRACTED}/opt/myscoutee/packaging/scripts/myscoutee-safe-copy.py" ]] \
  || fail "safe-copy helper is not executable"
[[ -x "${EXTRACTED}/opt/myscoutee/packaging/scripts/ensure-operator-bootstrap.sh" ]] \
  || fail "Operator bootstrap helper is not executable"
[[ -x "${EXTRACTED}/opt/myscoutee/packaging/scripts/myscoutee-tls-worker.sh" ]] \
  || fail "privileged TLS worker is not executable"
UPDATE_PATH_UNIT="${EXTRACTED}/lib/systemd/system/myscoutee-update.path"
grep -Fxq \
  'DirectoryNotEmpty=/var/lib/myscoutee/update/inbox/requests' \
  "${UPDATE_PATH_UNIT}" \
  || fail "packaged update path unit does not watch every inbox entry"
if grep -Eq '^[[:space:]]*PathExistsGlob=' "${UPDATE_PATH_UNIT}"; then
  fail "packaged update path unit still filters inbox entries by glob"
fi
TLS_PATH_UNIT="${EXTRACTED}/lib/systemd/system/myscoutee-tls.path"
grep -Fxq \
  'DirectoryNotEmpty=/var/lib/myscoutee/tls/inbox/requests' \
  "${TLS_PATH_UNIT}" \
  || fail "packaged TLS path unit does not watch the fixed inbox"
grep -Fxq 'Persistent=true' \
  "${EXTRACTED}/lib/systemd/system/myscoutee-tls-renew.timer" \
  || fail "packaged TLS renewal timer is not persistent"

KEY_HELPER="${EXTRACTED}/opt/myscoutee/packaging/scripts/ensure-operator-configuration-key.sh"
KEY_DIR="${TEST_ROOT}/configuration"
MYSCOUTEE_OPERATOR_CONFIGURATION_KEY_DIR="${KEY_DIR}" \
MYSCOUTEE_CONFIGURATION_OWNER_UID="$(id -u)" \
MYSCOUTEE_CONFIGURATION_OWNER_GID="$(id -g)" \
  "${KEY_HELPER}"
first_key="$(tr -d '\n' < "${KEY_DIR}/deployment-master-key")"
[[ "${first_key}" =~ ^[0-9a-f]{64}$ ]] \
  || fail "operator configuration helper generated an invalid key"
MYSCOUTEE_OPERATOR_CONFIGURATION_KEY_DIR="${KEY_DIR}" \
MYSCOUTEE_CONFIGURATION_OWNER_UID="$(id -u)" \
MYSCOUTEE_CONFIGURATION_OWNER_GID="$(id -g)" \
  "${KEY_HELPER}"
[[ "$(tr -d '\n' < "${KEY_DIR}/deployment-master-key")" == "${first_key}" ]] \
  || fail "operator configuration helper rotated an existing key"
[[ "$(stat -c '%a' "${KEY_DIR}")" == "750" \
  && "$(stat -c '%a' "${KEY_DIR}/deployment-master-key")" == "640" ]] \
  || fail "operator configuration key permissions are incorrect"
INVALID_KEY_DIR="${TEST_ROOT}/invalid-configuration"
mkdir "${INVALID_KEY_DIR}"
printf '6%.0s' {1..32} > "${INVALID_KEY_DIR}/deployment-master-key"
printf '\n' >> "${INVALID_KEY_DIR}/deployment-master-key"
printf '6%.0s' {1..32} >> "${INVALID_KEY_DIR}/deployment-master-key"
if MYSCOUTEE_OPERATOR_CONFIGURATION_KEY_DIR="${INVALID_KEY_DIR}" \
  MYSCOUTEE_CONFIGURATION_OWNER_UID="$(id -u)" \
  MYSCOUTEE_CONFIGURATION_OWNER_GID="$(id -g)" \
    "${KEY_HELPER}" >/dev/null 2>&1; then
  fail "operator configuration helper accepted an embedded newline"
fi
grep -Fq \
  '${PACKAGE_ROOT}/packaging/scripts/ensure-operator-configuration-key.sh' \
  "${TEST_ROOT}/debian/postinst" \
  || fail "postinst does not run the persistent key initializer"
for collection in \
  operatorRegistryEndpoints paymentProviders deploymentConfigurations exchangeRates; do
  grep -Fq "${collection}" \
    "${EXTRACTED}/opt/myscoutee/packaging/templates/myscoutee.env" \
    || fail "production seed allow-list omits ${collection}"
done

REAL_FIREBASE="${REPO_ROOT}/server/projects/profile/secrets/firebase-service-account.json"
if [[ -f "${REAL_FIREBASE}" ]]; then
  private_key_id="$(jq -r '.private_key_id // ""' "${REAL_FIREBASE}")"
  client_email="$(jq -r '.client_email // ""' "${REAL_FIREBASE}")"
  if [[ -n "${private_key_id}" ]] \
    && grep -R -Fq -- "${private_key_id}" "${EXTRACTED}"; then
    fail "a real Firebase private-key identifier leaked into package content"
  fi
  if [[ -n "${client_email}" ]] \
    && grep -R -Fq -- "${client_email}" "${EXTRACTED}"; then
    fail "a real Firebase service-account identity leaked into package content"
  fi
fi

SECRETS_TEMPLATE="${EXTRACTED}/opt/myscoutee/packaging/templates/myscoutee.secrets.env"
for external_key in \
  FACEBOOK_APP_SECRET \
  FCM_API_KEY \
  PAYMENT_STRIPE_API_KEY \
  PAYMENT_BARION_API_KEY \
  EMAIL_SENDGRID_API_KEY; do
  external_value="$(
    sed -n "s/^${external_key}=//p" "${SECRETS_TEMPLATE}" | tail -n 1
  )"
  [[ -z "${external_value}" ]] \
    || fail "${external_key} must be supplied after installation, not embedded in the package"
done
for generated_internal_key in \
  PAYMENT_SIMULATOR_API_KEY \
  PAYMENT_SIMULATOR_WEBHOOK_SECRET \
  PAYMENT_SIMULATOR_BARION_POS_KEY; do
  generated_value="$(
    sed -n "s/^${generated_internal_key}=//p" "${SECRETS_TEMPLATE}" | tail -n 1
  )"
  [[ -z "${generated_value}" ]] \
    || fail "${generated_internal_key} must be generated during installation"
  jq -e --arg key "${generated_internal_key}" \
    'any(.freshSecrets[]; .key == $key) and any(.ensureSecrets[]; .key == $key)' \
    "${EXTRACTED}/opt/myscoutee/packaging/templates/install-policy.json" >/dev/null \
    || fail "postinst does not provision ${generated_internal_key}"
done
if grep -RIl \
  --exclude='*.example' \
  --exclude='audit-package-credentials.sh' \
  --exclude='audit-nested-archive.py' \
  -E -- '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----|-----BEGIN PGP PRIVATE KEY BLOCK-----' \
  "${EXTRACTED}" \
  | grep -q .; then
  fail "private key material was embedded in the package"
fi

AUDIT_FIXTURE="${TEST_ROOT}/credential-audit"
mkdir -p \
  "${AUDIT_FIXTURE}/opt/myscoutee/packaging/templates" \
  "${AUDIT_FIXTURE}/opt/myscoutee/server/projects/profile/secrets"
cp \
  "${REPO_ROOT}/config/packaging/templates/myscoutee.secrets.env" \
  "${AUDIT_FIXTURE}/opt/myscoutee/packaging/templates/myscoutee.secrets.env"
bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}"

printf '%s\n' '{"type":"service_account","private_key":"test-only"}' \
  > "${AUDIT_FIXTURE}/opt/myscoutee/server/projects/profile/secrets/firebase-service-account.json"
if bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}" >/dev/null 2>&1; then
  fail "credential audit accepted an external Firebase service-account file"
fi
rm -f \
  "${AUDIT_FIXTURE}/opt/myscoutee/server/projects/profile/secrets/firebase-service-account.json"

sed -i \
  's/^PAYMENT_STRIPE_API_KEY=.*/PAYMENT_STRIPE_API_KEY=test-only-token/' \
  "${AUDIT_FIXTURE}/opt/myscoutee/packaging/templates/myscoutee.secrets.env"
if bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}" >/dev/null 2>&1; then
  fail "credential audit accepted an embedded external provider token"
fi
cp \
  "${REPO_ROOT}/config/packaging/templates/myscoutee.secrets.env" \
  "${AUDIT_FIXTURE}/opt/myscoutee/packaging/templates/myscoutee.secrets.env"

sed -i \
  's/^OPERATOR_BOOTSTRAP_EMAIL=.*/OPERATOR_BOOTSTRAP_EMAIL=operator-aaaaaaaaaaaaaaaaaaaaaaaa@deployment.invalid/' \
  "${AUDIT_FIXTURE}/opt/myscoutee/packaging/templates/myscoutee.secrets.env"
if bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}" >/dev/null 2>&1; then
  fail "credential audit accepted a fixed Operator bootstrap subject"
fi
cp \
  "${REPO_ROOT}/config/packaging/templates/myscoutee.secrets.env" \
  "${AUDIT_FIXTURE}/opt/myscoutee/packaging/templates/myscoutee.secrets.env"

sed -i \
  's/^MONGO_APP_PASSWORD=.*/MONGO_APP_PASSWORD=fixed-test-only-password/' \
  "${AUDIT_FIXTURE}/opt/myscoutee/packaging/templates/myscoutee.secrets.env"
if bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}" >/dev/null 2>&1; then
  fail "credential audit accepted a fixed internal password instead of an install-time placeholder"
fi
cp \
  "${REPO_ROOT}/config/packaging/templates/myscoutee.secrets.env" \
  "${AUDIT_FIXTURE}/opt/myscoutee/packaging/templates/myscoutee.secrets.env"

sed -i \
  's/^OPERATOR_BOOTSTRAP_PASSWORD_SHA256=.*/OPERATOR_BOOTSTRAP_PASSWORD_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
  "${AUDIT_FIXTURE}/opt/myscoutee/packaging/templates/myscoutee.secrets.env"
if bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}" >/dev/null 2>&1; then
  fail "credential audit accepted a fixed Operator bootstrap password digest"
fi
cp \
  "${REPO_ROOT}/config/packaging/templates/myscoutee.secrets.env" \
  "${AUDIT_FIXTURE}/opt/myscoutee/packaging/templates/myscoutee.secrets.env"

IMAGE_BUILD="${TEST_ROOT}/image-build"
IMAGE_LAYER_ROOT="${IMAGE_BUILD}/layer-root"
IMAGE_ARCHIVE_DIR="${AUDIT_FIXTURE}/opt/myscoutee/images"
mkdir -p "${IMAGE_LAYER_ROOT}/app" "${IMAGE_ARCHIVE_DIR}"
printf '%s\n' 'safe fixture' > "${IMAGE_LAYER_ROOT}/app/README"
mkdir -p "${IMAGE_LAYER_ROOT}/etc/ImageMagick-7"
printf '%s\n' \
  '<mime magic="-----BEGIN PGP PRIVATE KEY BLOCK-----" />' \
  > "${IMAGE_LAYER_ROOT}/etc/ImageMagick-7/mime.xml"
tar -cf "${IMAGE_BUILD}/layer.tar" -C "${IMAGE_LAYER_ROOT}" .
jq -n \
  '{config:{Env:["MONGO_APP_PASSWORD=replace-with-install-generated-password"]}}' \
  > "${IMAGE_BUILD}/config.json"
jq -n \
  '[{Config:"config.json",RepoTags:["test-only:1.0.0"],Layers:["layer.tar"]}]' \
  > "${IMAGE_BUILD}/manifest.json"
tar -cf "${IMAGE_ARCHIVE_DIR}/test-only.tar" \
  -C "${IMAGE_BUILD}" manifest.json config.json layer.tar
bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}"

printf '%s\n' \
  '-----BEGIN PRIVATE KEY-----' \
  'dGVzdC1vbmx5LW5vdC1hLXJlYWwta2V5' \
  '-----END PRIVATE KEY-----' \
  > "${IMAGE_LAYER_ROOT}/app/embedded-key.pem"
tar -cf "${IMAGE_BUILD}/layer.tar" -C "${IMAGE_LAYER_ROOT}" .
tar -cf "${IMAGE_ARCHIVE_DIR}/test-only.tar" \
  -C "${IMAGE_BUILD}" manifest.json config.json layer.tar
if bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}" >/dev/null 2>&1; then
  fail "credential audit accepted private-key material inside a managed image layer"
fi
rm -f "${IMAGE_LAYER_ROOT}/app/embedded-key.pem"

mkdir -p "${IMAGE_LAYER_ROOT}/usr/share/nginx/html"
printf '%s\n' 'Third-party license contact: jaffathecake@gmail.com' \
  > "${IMAGE_LAYER_ROOT}/usr/share/nginx/html/3rdpartylicenses.txt"
printf '%s\n' \
  'Placeholder: https://facebook.com/username' \
  'Placeholder: https://instagram.com/username' \
  'Provider terms: https://www.facebook.com/legal/terms' \
  > "${IMAGE_LAYER_ROOT}/usr/share/nginx/html/main.js"
tar -cf "${IMAGE_BUILD}/layer.tar" -C "${IMAGE_LAYER_ROOT}" .
tar -cf "${IMAGE_ARCHIVE_DIR}/test-only.tar" \
  -C "${IMAGE_BUILD}" manifest.json config.json layer.tar
bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}"

printf '%s\n' 'window.__deploymentOwner = "owner@gmail.com";' \
  > "${IMAGE_LAYER_ROOT}/usr/share/nginx/html/main.js"
tar -cf "${IMAGE_BUILD}/layer.tar" -C "${IMAGE_LAYER_ROOT}" .
tar -cf "${IMAGE_ARCHIVE_DIR}/test-only.tar" \
  -C "${IMAGE_BUILD}" manifest.json config.json layer.tar
if bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}" >/dev/null 2>&1; then
  fail "credential audit accepted a personal email in managed frontend application content"
fi
rm -f "${IMAGE_LAYER_ROOT}/usr/share/nginx/html/main.js"

mkdir -p "${IMAGE_LAYER_ROOT}/run/secrets"
printf '%s\n' '{"type":"service_account","private_key":"test-only"}' \
  > "${IMAGE_LAYER_ROOT}/run/secrets/firebase-service-account.json"
tar -cf "${IMAGE_BUILD}/layer.tar" -C "${IMAGE_LAYER_ROOT}" .
tar -cf "${IMAGE_ARCHIVE_DIR}/test-only.tar" \
  -C "${IMAGE_BUILD}" manifest.json config.json layer.tar
if bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}" >/dev/null 2>&1; then
  fail "credential audit accepted an external credential inside a managed image layer"
fi

rm -f "${IMAGE_LAYER_ROOT}/run/secrets/firebase-service-account.json"
python3 -c \
  'import sys, zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("com/google/api/client/googleapis/google.p12", b"unreviewed-credential"); z.close()' \
  "${IMAGE_LAYER_ROOT}/app/unreviewed-truststore.jar"
if python3 "${MYSCOUTEE_PACKAGING_SOURCE:-${REPO_ROOT}/../myscoutee-packaging}/release/audit/audit-nested-archive.py" \
    "${IMAGE_LAYER_ROOT}/app/unreviewed-truststore.jar" >/dev/null 2>&1; then
  fail "credential audit trusted a PKCS12 filename without its reviewed digest"
fi
rm -f "${IMAGE_LAYER_ROOT}/app/unreviewed-truststore.jar"
python3 -c \
  'import sys, zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("BOOT-INF/classes/firebase-service-account.json", "{}"); z.close()' \
  "${IMAGE_LAYER_ROOT}/app/application.jar"
tar -cf "${IMAGE_BUILD}/layer.tar" -C "${IMAGE_LAYER_ROOT}" .
tar -cf "${IMAGE_ARCHIVE_DIR}/test-only.tar" \
  -C "${IMAGE_BUILD}" manifest.json config.json layer.tar
if bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}" >/dev/null 2>&1; then
  fail "credential audit accepted an external credential inside a nested managed-image JAR"
fi

python3 -c \
  'import sys, zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("BOOT-INF/classes/application-prod.yaml", "config:\\n  adminUser: owner@gmail.com\\n"); z.close()' \
  "${IMAGE_LAYER_ROOT}/app/application.jar"
tar -cf "${IMAGE_BUILD}/layer.tar" -C "${IMAGE_LAYER_ROOT}" .
tar -cf "${IMAGE_ARCHIVE_DIR}/test-only.tar" \
  -C "${IMAGE_BUILD}" manifest.json config.json layer.tar
if bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}" >/dev/null 2>&1; then
  fail "credential audit accepted a personal admin identity inside a managed-image JAR"
fi

python3 -c \
  'import sys, zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("BOOT-INF/classes/application-prod.yaml", "landing:\\n  social: https://instagram.com/private-demo-owner\\n"); z.close()' \
  "${IMAGE_LAYER_ROOT}/app/application.jar"
tar -cf "${IMAGE_BUILD}/layer.tar" -C "${IMAGE_LAYER_ROOT}" .
tar -cf "${IMAGE_ARCHIVE_DIR}/test-only.tar" \
  -C "${IMAGE_BUILD}" manifest.json config.json layer.tar
if bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}" >/dev/null 2>&1; then
  fail "credential audit accepted a personal social-page URL inside a managed-image JAR"
fi

python3 -c \
  'import sys, zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("BOOT-INF/classes/application-prod.yaml", "config:\\n  operator-bootstrap-password-sha256: ${OPERATOR_BOOTSTRAP_PASSWORD_SHA256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}\\n"); z.close()' \
  "${IMAGE_LAYER_ROOT}/app/application.jar"
tar -cf "${IMAGE_BUILD}/layer.tar" -C "${IMAGE_LAYER_ROOT}" .
tar -cf "${IMAGE_ARCHIVE_DIR}/test-only.tar" \
  -C "${IMAGE_BUILD}" manifest.json config.json layer.tar
if bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}" >/dev/null 2>&1; then
  fail "credential audit accepted a fixed Operator bootstrap digest inside a managed-image JAR"
fi

python3 -c \
  'import sys, zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("BOOT-INF/classes/application-prod.yaml", "config:\\n  operator-bootstrap-email: ${OPERATOR_BOOTSTRAP_EMAIL:operator-aaaaaaaaaaaaaaaaaaaaaaaa@deployment.invalid}\\n"); z.close()' \
  "${IMAGE_LAYER_ROOT}/app/application.jar"
tar -cf "${IMAGE_BUILD}/layer.tar" -C "${IMAGE_LAYER_ROOT}" .
tar -cf "${IMAGE_ARCHIVE_DIR}/test-only.tar" \
  -C "${IMAGE_BUILD}" manifest.json config.json layer.tar
if bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}" >/dev/null 2>&1; then
  fail "credential audit accepted a fixed Operator bootstrap subject inside a managed-image JAR"
fi
rm -rf "${IMAGE_ARCHIVE_DIR}" "${IMAGE_BUILD}"

printf '%s\n' \
  '-----BEGIN PRIVATE KEY-----' \
  'dGVzdC1vbmx5LW5vdC1hLXJlYWwta2V5' \
  '-----END PRIVATE KEY-----' \
  > "${AUDIT_FIXTURE}/opt/myscoutee/server/projects/profile/secrets/provider-key.pem"
if bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}" >/dev/null 2>&1; then
  fail "credential audit accepted embedded private-key material"
fi
rm -f \
  "${AUDIT_FIXTURE}/opt/myscoutee/server/projects/profile/secrets/provider-key.pem"

printf '%s\n' 'https://facebook.com/private-demo-owner' \
  > "${AUDIT_FIXTURE}/opt/myscoutee/packaging/templates/personal-social.txt"
if bash "${CREDENTIAL_AUDIT}" "${AUDIT_FIXTURE}" >/dev/null 2>&1; then
  fail "credential audit accepted a personal social-page URL"
fi
rm -f "${AUDIT_FIXTURE}/opt/myscoutee/packaging/templates/personal-social.txt"

PACKAGED_APP_SETTINGS="${PACKAGED_PRODUCTION_SEED}/appSettings.json"
cp "${PACKAGED_APP_SETTINGS}" "${TEST_ROOT}/appSettings.safe.json"
jq 'map(if .settingsKey == "global" then .adminEmails = ["owner@gmail.com"] else . end)' \
  "${TEST_ROOT}/appSettings.safe.json" > "${PACKAGED_APP_SETTINGS}"
if bash "${CREDENTIAL_AUDIT}" "${EXTRACTED}" >/dev/null 2>&1; then
  fail "credential audit accepted a personal production administrator seed"
fi
mv "${TEST_ROOT}/appSettings.safe.json" "${PACKAGED_APP_SETTINGS}"

PACKAGED_DEPLOYMENT_CONFIGURATION="${PACKAGED_PRODUCTION_SEED}/deploymentConfigurations.json"
cp "${PACKAGED_DEPLOYMENT_CONFIGURATION}" \
  "${TEST_ROOT}/deploymentConfigurations.safe.json"
jq '.[0].privacyContact = {
      dataControllerName: "Packaged Operator",
      privacyContactEmail: "owner@gmail.com"
    }' \
  "${TEST_ROOT}/deploymentConfigurations.safe.json" \
  > "${PACKAGED_DEPLOYMENT_CONFIGURATION}"
if bash "${CREDENTIAL_AUDIT}" "${EXTRACTED}" >/dev/null 2>&1; then
  fail "credential audit accepted a fixed production privacy contact"
fi
mv "${TEST_ROOT}/deploymentConfigurations.safe.json" \
  "${PACKAGED_DEPLOYMENT_CONFIGURATION}"

PACKAGED_HELP_CENTER="${PACKAGED_PRODUCTION_SEED}/helpCenterRevisions.json"
cp "${PACKAGED_HELP_CENTER}" "${TEST_ROOT}/helpCenterRevisions.safe.json"
jq 'map(
      if .documentType == "privacy" and .lang == "en"
      then .sections |= map(
        if .id == "contact-details"
        then .contentHtml = "<p>DPO: owner@gmail.com</p>"
        else .
        end
      )
      else .
      end
    )' \
  "${TEST_ROOT}/helpCenterRevisions.safe.json" \
  > "${PACKAGED_HELP_CENTER}"
if bash "${CREDENTIAL_AUDIT}" "${EXTRACTED}" >/dev/null 2>&1; then
  fail "credential audit accepted fixed contact data in production privacy help"
fi
mv "${TEST_ROOT}/helpCenterRevisions.safe.json" "${PACKAGED_HELP_CENTER}"

printf '[]\n' > "${PACKAGED_PRODUCTION_SEED}/users.json"
if bash "${CREDENTIAL_AUDIT}" "${EXTRACTED}" >/dev/null 2>&1; then
  fail "credential audit accepted a production user fixture"
fi
rm -f "${PACKAGED_PRODUCTION_SEED}/users.json"

cp "${PACKAGED_PRODUCTION_SEED}/communityProviders.json" "${TEST_ROOT}/communityProviders.safe.json"
printf '%s\n' \
  '[{"_id":"personal-social","url":"https://linkedin.com/in/private-owner"}]' \
  > "${PACKAGED_PRODUCTION_SEED}/communityProviders.json"
if bash "${CREDENTIAL_AUDIT}" "${EXTRACTED}" >/dev/null 2>&1; then
  fail "credential audit accepted a personal production social-page seed"
fi
cp "${TEST_ROOT}/communityProviders.safe.json" "${PACKAGED_PRODUCTION_SEED}/communityProviders.json"
jq '.[0].configured = true' "${TEST_ROOT}/communityProviders.safe.json" \
  > "${PACKAGED_PRODUCTION_SEED}/communityProviders.json"
if bash "${CREDENTIAL_AUDIT}" "${EXTRACTED}" >/dev/null 2>&1; then
  fail "credential audit accepted a preconfigured production community provider"
fi
cp "${TEST_ROOT}/communityProviders.safe.json" "${PACKAGED_PRODUCTION_SEED}/communityProviders.json"

if MYSCOUTEE_VERSION=1.0.0-prod \
  MYSCOUTEE_DIST_DIR="${TEST_ROOT}/invalid-dist" \
  BUILD_ARTIFACTS=false \
  PACKAGE_IMAGES=false \
  ALLOW_UNBUNDLED_IMAGES_FOR_TESTS=true \
  bash "${PACKAGE_SCRIPT}" >/dev/null 2>&1; then
  fail "suffixed Debian package version was accepted"
fi

# QA releases use SemVer for application/image identity and Debian's tilde
# ordering for the package manager. Exercise the normal builder, not repacking.
qa_deb="$(
  MYSCOUTEE_VERSION=1.0.0-qa.1 \
  MYSCOUTEE_DIST_DIR="${TEST_ROOT}/qa-dist" \
  BUILD_ARTIFACTS=false PACKAGE_IMAGES=false ALLOW_UNBUNDLED_IMAGES_FOR_TESTS=true \
  bash "${PACKAGE_SCRIPT}" | tail -n 1
)"
[[ "$(dpkg-deb -f "${qa_deb}" Version)" == '1.0.0~qa.1' ]] \
  || fail "QA package lacks Debian prerelease ordering"
dpkg-deb -x "${qa_deb}" "${TEST_ROOT}/qa-package"
grep -Fxq '1.0.0-qa.1' "${TEST_ROOT}/qa-package/opt/myscoutee/packaging/VERSION" \
  || fail "QA application version marker does not match the release"
[[ -f "${TEST_ROOT}/qa-dist/myscoutee-client-tools_1.0.0-qa.1.tar.gz" ]] \
  || fail "QA client tools do not use the release version"
dpkg --compare-versions 1.0.0~qa.1 lt 1.0.0 \
  || fail "QA package must sort before stable 1.0.0"
if grep -q 'sync_frontend_assets.sh' "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/build-production.sh"; then
  fail "production builder must not overwrite the dev nginx frontend"
fi

echo "package content tests passed"
