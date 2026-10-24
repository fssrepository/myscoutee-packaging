#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/myscoutee-update-worker-test.XXXXXX)"
WORKER_SOURCE="$TEST_ROOT/worker-source"
mkdir "$WORKER_SOURCE"
for input in runtime/update/myscoutee-update-worker.sh runtime/update/myscoutee-safe-copy.py \
 release/lib/image-content-fingerprint.sh release/lib/release-project.sh; do
 cp "$SOURCE_ROOT/$input" "$WORKER_SOURCE/"
done
install -m 0644 "$SOURCE_ROOT/tests/fixtures/update-worker/release-project.json" "$WORKER_SOURCE/release-project.json"
WORKER_SCRIPT="$WORKER_SOURCE/myscoutee-update-worker.sh"
SAFE_COPY_HELPER="$WORKER_SOURCE/myscoutee-safe-copy.py"
FINGERPRINT_HELPER="$WORKER_SOURCE/image-content-fingerprint.sh"


cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

for command_name in jq openssl sha256sum base64 stat dpkg dpkg-deb tar python3; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "required test command is missing: ${command_name}"
done
[[ -x "${FINGERPRINT_HELPER}" && ! -L "${FINGERPRINT_HELPER}" ]] \
  || fail "image content fingerprint helper is missing or unsafe"

STATE_ROOT="${TEST_ROOT}/state"
CACHE_ROOT="${TEST_ROOT}/cache"
AUDIT_ROOT="${TEST_ROOT}/audit"
FAKE_BIN="${TEST_ROOT}/bin"
VERSION_FILE="${TEST_ROOT}/installed-version"
APT_CALLS_FILE="${TEST_ROOT}/apt-calls"
BACKUP_FILE="${TEST_ROOT}/backup.tar.gz"
BACKUP_HELPER="${TEST_ROOT}/backup.sh"
INSTALLED_MANIFEST="${TEST_ROOT}/installed-image-manifest.json"
PRIVATE_KEY="${TEST_ROOT}/release-private-key.pem"
PUBLIC_KEY="${TEST_ROOT}/release-public-key.pem"
PUBLIC_DER="${TEST_ROOT}/release-public-key.der"
PACKAGE_ROOT="${TEST_ROOT}/package-root"
PACKAGE_PATH="${TEST_ROOT}/myscoutee_999.0.0_test.deb"
PACKAGE_VERSION="${UPDATE_TEST_RELEASE_VERSION:-999.0.0}"
DEBIAN_PACKAGE_VERSION="${PACKAGE_VERSION/-/\~}"
PACKAGE_CHANNEL="stable"
HOST_ARCH="$(dpkg --print-architecture)"
IMAGE_INSPECT_DIR="${TEST_ROOT}/image-inspect"
NGIN_BASE_ID="sha256:$(printf '1%.0s' {1..64})"
NGIN_ID="sha256:$(printf '2%.0s' {1..64})"
API_ID="sha256:$(printf '3%.0s' {1..64})"
MINIO_ID="sha256:$(printf '4%.0s' {1..64})"
REGISTRY_DEMO_ID="sha256:$(printf '5%.0s' {1..64})"
PAYMENT_SIMULATOR_ID="sha256:$(printf '6%.0s' {1..64})"
MCP_ID="sha256:$(printf '8%.0s' {1..64})"
API_RUNTIME_ID="sha256:$(printf '7%.0s' {1..64})"
BAD_API_ID="sha256:$(printf '0%.0s' {1..64})"

mkdir -p \
  "${FAKE_BIN}" \
  "${IMAGE_INSPECT_DIR}" \
  "${PACKAGE_ROOT}/DEBIAN" \
  "${PACKAGE_ROOT}/opt/myscoutee/packaging"
printf '%s\n' '1.0.0' > "${VERSION_FILE}"
: > "${APT_CALLS_FILE}"

openssl genpkey -algorithm ED25519 -out "${PRIVATE_KEY}"
openssl pkey -in "${PRIVATE_KEY}" -pubout -out "${PUBLIC_KEY}"
openssl pkey -in "${PRIVATE_KEY}" -pubout -outform DER -out "${PUBLIC_DER}"
PUBLIC_KEY_DIGEST="$(sha256sum "${PUBLIC_DER}" | awk '{ print $1 }')"
PACKAGE_KEY_ID="pkey_${PUBLIC_KEY_DIGEST:0:32}"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'cat "${UPDATE_TEST_VERSION_FILE}"' \
  > "${FAKE_BIN}/dpkg-query"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "[myscoutee-update-phase] LOADING_IMAGES\n"' \
  'artifact="${*: -1}"' \
  'version="$(/usr/bin/dpkg-deb -f "${artifact}" Version)"' \
  'printf "%s\n" "${version}" > "${UPDATE_TEST_VERSION_FILE}"' \
  '/usr/bin/dpkg-deb --fsys-tarfile "${artifact}" | /usr/bin/tar -xOf - ./opt/myscoutee/packaging/IMAGE-MANIFEST.json > "${UPDATE_TEST_INSTALLED_MANIFEST}"' \
  'printf "%s\n" "$*" >> "${UPDATE_TEST_APT_CALLS_FILE}"' \
  > "${FAKE_BIN}/apt-get"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exit 0' \
  > "${FAKE_BIN}/systemctl"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "${1:-}" == "image" && "${2:-}" == "inspect" && "${3:-}" == "--" ]]; then' \
  '  case "${4:-}" in' \
  '    "${UPDATE_TEST_NGINX_BASE_ID}") fixture="${UPDATE_TEST_NGINX_BASE_INSPECT}" ;;' \
  '    "${UPDATE_TEST_NGINX_ID}") fixture="${UPDATE_TEST_NGINX_INSPECT}" ;;' \
  '    "${UPDATE_TEST_API_ID}") fixture="${UPDATE_TEST_API_INSPECT}" ;;' \
  '    "${UPDATE_TEST_API_RUNTIME_ID}") fixture="${UPDATE_TEST_API_RUNTIME_INSPECT}" ;;' \
  '    "${UPDATE_TEST_MINIO_ID}") fixture="${UPDATE_TEST_MINIO_INSPECT}" ;;' \
  '    "${UPDATE_TEST_REGISTRY_DEMO_ID}") fixture="${UPDATE_TEST_REGISTRY_DEMO_INSPECT}" ;;' \
  '    "${UPDATE_TEST_PAYMENT_SIMULATOR_ID}") fixture="${UPDATE_TEST_PAYMENT_SIMULATOR_INSPECT}" ;;' \
  '    "${UPDATE_TEST_MCP_ID}") fixture="${UPDATE_TEST_MCP_INSPECT}" ;;' \
  '    "${UPDATE_TEST_BAD_API_ID}") fixture="${UPDATE_TEST_BAD_API_INSPECT}" ;;' \
  '    *) exit 1 ;;' \
  '  esac' \
  '  cat "${fixture}"' \
  '  exit 0' \
  'fi' \
  'format="${3:-}"' \
  'container="${4:-}"' \
  'if [[ "${1:-}" != "inspect" || "${2:-}" != "--format" ]]; then exit 1; fi' \
  'case "${format}" in' \
  '  "{{.Config.Image}}")' \
  '    case "${container}" in' \
  '      nginx) printf "%s\n" "myscoutee-nginx:${UPDATE_TEST_RELEASE_VERSION:-999.0.0}-prod" ;;' \
  '      myscoutee) printf "%s\n" "myscoutee-api:${UPDATE_TEST_RELEASE_VERSION:-999.0.0}-prod" ;;' \
  '      minio) printf "%s\n" "myscoutee-minio:${UPDATE_TEST_RELEASE_VERSION:-999.0.0}-prod" ;;' \
  '      registry-demo) printf "%s\n" "myscoutee-registry:${UPDATE_TEST_RELEASE_VERSION:-999.0.0}-prod" ;;' \
  '      payment-simulator) printf "%s\n" "myscoutee-payment-simulator:${UPDATE_TEST_RELEASE_VERSION:-999.0.0}-prod" ;;' \
  '      mcp) printf "%s\n" "myscoutee-mcp:${UPDATE_TEST_RELEASE_VERSION:-999.0.0}-prod" ;;' \
  '      *) exit 1 ;;' \
  '    esac' \
  '    ;;' \
  '  "{{.Image}}")' \
  '    if [[ "${UPDATE_TEST_BAD_IMAGE:-false}" == "true" && "${container}" == "myscoutee" ]]; then' \
  '      printf "%s\n" "${UPDATE_TEST_BAD_API_ID}"' \
  '    else' \
  '      case "${container}" in' \
  '        nginx) printf "%s\n" "${UPDATE_TEST_NGINX_ID}" ;;' \
  '        myscoutee) printf "%s\n" "${UPDATE_TEST_API_RUNTIME_ID}" ;;' \
  '        minio) printf "%s\n" "${UPDATE_TEST_MINIO_ID}" ;;' \
  '        registry-demo) printf "%s\n" "${UPDATE_TEST_REGISTRY_DEMO_ID}" ;;' \
  '        payment-simulator) printf "%s\n" "${UPDATE_TEST_PAYMENT_SIMULATOR_ID}" ;;' \
  '        mcp) printf "%s\n" "${UPDATE_TEST_MCP_ID}" ;;' \
  '        *) exit 1 ;;' \
  '      esac' \
  '    fi' \
  '    ;;' \
  '  *) printf "%s\n" healthy ;;' \
  'esac' \
  > "${FAKE_BIN}/docker"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'touch "${UPDATE_TEST_BACKUP_FILE}"' \
  'echo "Unexpected automatic production backup" >&2' \
  'exit 1' \
  > "${BACKUP_HELPER}"
chmod 0755 \
  "${FAKE_BIN}/dpkg-query" \
  "${FAKE_BIN}/apt-get" \
  "${FAKE_BIN}/systemctl" \
  "${FAKE_BIN}/docker" \
  "${BACKUP_HELPER}" \
  "${SAFE_COPY_HELPER}"

write_image_fixture() {
  local fixture_name="$1"
  local image_id="$2"
  local service="$3"
  local run_user="$4"
  local config_path="${IMAGE_INSPECT_DIR}/${fixture_name}-config.json"
  local inspect_path="${IMAGE_INSPECT_DIR}/${fixture_name}-inspect.json"

  jq -n \
    --arg service "${service}" \
    --arg runUser "${run_user}" \
    --arg layer "${image_id}" \
    '{
      architecture: "amd64",
      os: "linux",
      config: {
        User: $runUser,
        Env: [
          ("SERVICE=" + $service),
          "TZ=Europe/Bratislava"
        ],
        Entrypoint: ["/usr/local/bin/entrypoint"],
        Cmd: ["serve", $service],
        WorkingDir: "/opt/myscoutee",
        Labels: {
          "com.myscoutee.fixture": $service,
          "org.opencontainers.image.vendor": "MyScoutee"
        },
        ExposedPorts: {
          "8080/tcp": {}
        },
        Volumes: {
          "/data": {}
        },
        Healthcheck: {
          Test: ["CMD", "/usr/local/bin/healthcheck"],
          Interval: 30000000000,
          Timeout: 3000000000,
          StartPeriod: 1000000000,
          Retries: 3
        },
        StopSignal: "SIGTERM",
        Shell: ["/bin/sh", "-c"]
      },
      rootfs: {
        type: "layers",
        diff_ids: [$layer]
      }
    }' > "${config_path}"
  jq --arg imageId "${image_id}" '
    [{
      Id: $imageId,
      RepoTags: ["daemon-local-id-is-not-release-identity:test"],
      Architecture: .architecture,
      Os: .os,
      Config: .config,
      RootFS: {
        Type: .rootfs.type,
        Layers: .rootfs.diff_ids
      }
    }]
  ' "${config_path}" > "${inspect_path}"
}

write_image_fixture \
  "nginx-base" "${NGIN_BASE_ID}" "nginx-base" "101:101"
write_image_fixture \
  "nginx" "${NGIN_ID}" "nginx" "101:101"
write_image_fixture \
  "api" "${API_ID}" "profilemanagement" "10001:10001"
jq --arg runtimeId "${API_RUNTIME_ID}" \
  '.[0].Id = $runtimeId' \
  "${IMAGE_INSPECT_DIR}/api-inspect.json" \
  > "${IMAGE_INSPECT_DIR}/api-runtime-inspect.json"
write_image_fixture \
  "minio" "${MINIO_ID}" "minio" "1000:1000"
write_image_fixture \
  "registry-demo" "${REGISTRY_DEMO_ID}" "registry-demo" "10002:10002"
write_image_fixture \
  "payment-simulator" "${PAYMENT_SIMULATOR_ID}" "payment-simulator" "65532:65532"
write_image_fixture \
  "mcp" "${MCP_ID}" "mcp" "65532:65532"
write_image_fixture \
  "bad-api" "${BAD_API_ID}" "tampered-profilemanagement" "10001:10001"

export UPDATE_TEST_VERSION_FILE="${VERSION_FILE}"
export UPDATE_TEST_APT_CALLS_FILE="${APT_CALLS_FILE}"
export UPDATE_TEST_INSTALLED_MANIFEST="${INSTALLED_MANIFEST}"
export UPDATE_TEST_BACKUP_FILE="${BACKUP_FILE}"
export UPDATE_TEST_NGINX_BASE_ID="${NGIN_BASE_ID}"
export UPDATE_TEST_NGINX_ID="${NGIN_ID}"
export UPDATE_TEST_API_ID="${API_ID}"
export UPDATE_TEST_API_RUNTIME_ID="${API_RUNTIME_ID}"
export UPDATE_TEST_MINIO_ID="${MINIO_ID}"
export UPDATE_TEST_REGISTRY_DEMO_ID="${REGISTRY_DEMO_ID}"
export UPDATE_TEST_PAYMENT_SIMULATOR_ID="${PAYMENT_SIMULATOR_ID}"
export UPDATE_TEST_MCP_ID="${MCP_ID}"
export UPDATE_TEST_BAD_API_ID="${BAD_API_ID}"
export UPDATE_TEST_NGINX_BASE_INSPECT="${IMAGE_INSPECT_DIR}/nginx-base-inspect.json"
export UPDATE_TEST_NGINX_INSPECT="${IMAGE_INSPECT_DIR}/nginx-inspect.json"
export UPDATE_TEST_API_INSPECT="${IMAGE_INSPECT_DIR}/api-inspect.json"
export UPDATE_TEST_API_RUNTIME_INSPECT="${IMAGE_INSPECT_DIR}/api-runtime-inspect.json"
export UPDATE_TEST_MINIO_INSPECT="${IMAGE_INSPECT_DIR}/minio-inspect.json"
export UPDATE_TEST_REGISTRY_DEMO_INSPECT="${IMAGE_INSPECT_DIR}/registry-demo-inspect.json"
export UPDATE_TEST_PAYMENT_SIMULATOR_INSPECT="${IMAGE_INSPECT_DIR}/payment-simulator-inspect.json"
export UPDATE_TEST_MCP_INSPECT="${IMAGE_INSPECT_DIR}/mcp-inspect.json"
export UPDATE_TEST_BAD_API_INSPECT="${IMAGE_INSPECT_DIR}/bad-api-inspect.json"
export PATH="${FAKE_BIN}:${PATH}"

fingerprint_config() {
  local config_path="$1"
  local fingerprint

  fingerprint="$("${FINGERPRINT_HELPER}" config - < "${config_path}")"
  [[ "${fingerprint}" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || fail "image content fingerprint helper returned an invalid digest"
  printf '%s' "${fingerprint}"
}

NGIN_BASE_FINGERPRINT="$(
  fingerprint_config "${IMAGE_INSPECT_DIR}/nginx-base-config.json"
)"
NGIN_FINGERPRINT="$(
  fingerprint_config "${IMAGE_INSPECT_DIR}/nginx-config.json"
)"
API_FINGERPRINT="$(
  fingerprint_config "${IMAGE_INSPECT_DIR}/api-config.json"
)"
MINIO_FINGERPRINT="$(
  fingerprint_config "${IMAGE_INSPECT_DIR}/minio-config.json"
)"
REGISTRY_DEMO_FINGERPRINT="$(
  fingerprint_config "${IMAGE_INSPECT_DIR}/registry-demo-config.json"
)"
PAYMENT_SIMULATOR_FINGERPRINT="$(
  fingerprint_config "${IMAGE_INSPECT_DIR}/payment-simulator-config.json"
)"
MCP_FINGERPRINT="$(
  fingerprint_config "${IMAGE_INSPECT_DIR}/mcp-config.json"
)"

[[ "$("${FINGERPRINT_HELPER}" docker "${API_RUNTIME_ID}")" \
  == "${API_FINGERPRINT}" ]] \
  || fail "OCI config and Docker inspect fingerprints are not portable"

jq -n \
  --arg version "${PACKAGE_VERSION}" \
  --arg nginxBaseId "${NGIN_BASE_ID}" \
  --arg nginxId "${NGIN_ID}" \
  --arg apiId "${API_ID}" \
  --arg minioId "${MINIO_ID}" \
  --arg registryDemoId "${REGISTRY_DEMO_ID}" \
  --arg paymentSimulatorId "${PAYMENT_SIMULATOR_ID}" \
  --arg mcpId "${MCP_ID}" \
  --arg nginxBaseFingerprint "${NGIN_BASE_FINGERPRINT}" \
  --arg nginxFingerprint "${NGIN_FINGERPRINT}" \
  --arg apiFingerprint "${API_FINGERPRINT}" \
  --arg minioFingerprint "${MINIO_FINGERPRINT}" \
  --arg registryDemoFingerprint "${REGISTRY_DEMO_FINGERPRINT}" \
  --arg paymentSimulatorFingerprint "${PAYMENT_SIMULATOR_FINGERPRINT}" \
  --arg mcpFingerprint "${MCP_FINGERPRINT}" \
  '{
    schemaVersion: 1,
    releaseVersion: $version,
    bundled: true,
    images: [
      {
        service: "nginx-base",
        container: null,
        reference: ("myscoutee-nginx:" + $version + "-base"),
        imageId: $nginxBaseId,
        contentFingerprint: $nginxBaseFingerprint
      },
      {
        service: "nginx",
        container: "nginx",
        reference: ("myscoutee-nginx:" + $version + "-prod"),
        imageId: $nginxId,
        contentFingerprint: $nginxFingerprint
      },
      {
        service: "profilemanagement",
        container: "myscoutee",
        reference: ("myscoutee-api:" + $version + "-prod"),
        imageId: $apiId,
        contentFingerprint: $apiFingerprint
      },
      {
        service: "minio",
        container: "minio",
        reference: ("myscoutee-minio:" + $version + "-prod"),
        imageId: $minioId,
        contentFingerprint: $minioFingerprint
      },
      {
        service: "registry-demo",
        container: "registry-demo",
        reference: ("myscoutee-registry:" + $version + "-prod"),
        imageId: $registryDemoId,
        contentFingerprint: $registryDemoFingerprint
      },
      {
        service: "payment-simulator",
        container: "payment-simulator",
        reference: ("myscoutee-payment-simulator:" + $version + "-prod"),
        imageId: $paymentSimulatorId,
        contentFingerprint: $paymentSimulatorFingerprint
      },
      {
        service: "mcp",
        container: "mcp",
        reference: ("myscoutee-mcp:" + $version + "-prod"),
        imageId: $mcpId,
        contentFingerprint: $mcpFingerprint
      }
    ]
  }' > "${PACKAGE_ROOT}/opt/myscoutee/packaging/IMAGE-MANIFEST.json"

printf '%s\n' \
  "Package: myscoutee" \
  "Version: ${DEBIAN_PACKAGE_VERSION}" \
  "Section: web" \
  "Priority: optional" \
  "Architecture: ${HOST_ARCH}" \
  "Maintainer: MyScoutee test" \
  "Description: update worker verification fixture" \
  > "${PACKAGE_ROOT}/DEBIAN/control"
dpkg-deb --root-owner-group --build \
  "${PACKAGE_ROOT}" "${PACKAGE_PATH}" >/dev/null

export MYSCOUTEE_UPDATE_STATE_DIR="${STATE_ROOT}"
export MYSCOUTEE_UPDATE_CACHE_DIR="${CACHE_ROOT}"
export MYSCOUTEE_UPDATE_AUDIT_DIR="${AUDIT_ROOT}"
export MYSCOUTEE_UPDATE_RELEASE_PUBLIC_KEY="${PUBLIC_KEY}"
export MYSCOUTEE_UPDATE_BACKUP_SCRIPT="${BACKUP_HELPER}"
export MYSCOUTEE_UPDATE_SAFE_COPY_HELPER="${SAFE_COPY_HELPER}"
export MYSCOUTEE_UPDATE_INSTALLED_MANIFEST_PATH="${INSTALLED_MANIFEST}"
export MYSCOUTEE_UPDATE_MIN_FREE_BYTES=1
export MYSCOUTEE_UPDATE_HEALTH_TIMEOUT_SECONDS=1
export MYSCOUTEE_UPDATE_RESTART_HELPER="${FAKE_BIN}/systemctl"
export MYSCOUTEE_UPDATE_CACHE_RETENTION_JOBS=2
export MYSCOUTEE_UPDATE_ENABLED=true
export MYSCOUTEE_API_USER_ID
MYSCOUTEE_API_USER_ID="$(id -u)"
export MYSCOUTEE_API_GROUP_ID
MYSCOUTEE_API_GROUP_ID="$(id -g)"
export MYSCOUTEE_UPDATE_WORKER_USER_ID
MYSCOUTEE_UPDATE_WORKER_USER_ID="$(id -u)"

# shellcheck source=../scripts/myscoutee-update-worker.sh
source "${WORKER_SCRIPT}"

prepare_directories
require_runtime

dpkg --compare-versions "$(debian_version 1.0.0-qa.3)" gt "$(debian_version 1.0.0-qa.1)" \
  || fail "skipped QA release versions are not ordered correctly"
dpkg --compare-versions "$(debian_version 1.0.0)" gt "$(debian_version 1.0.0-qa.3)" \
  || fail "stable release must be newer than its QA prerelease"

CURRENT_RELEASE_VERSION="${PACKAGE_VERSION}"
validate_image_manifest \
  "${PACKAGE_ROOT}/opt/myscoutee/packaging/IMAGE-MANIFEST.json" \
  || fail "content-fingerprint image manifest was rejected"
MISSING_FINGERPRINT_MANIFEST="${TEST_ROOT}/missing-content-fingerprint.json"
jq 'del(.images[0].contentFingerprint)' \
  "${PACKAGE_ROOT}/opt/myscoutee/packaging/IMAGE-MANIFEST.json" \
  > "${MISSING_FINGERPRINT_MANIFEST}"
if validate_image_manifest "${MISSING_FINGERPRINT_MANIFEST}"; then
  fail "image manifest without a content fingerprint was accepted"
fi
# Old six-image releases remain verifiable for rollback; newer candidates
# cannot omit MCP, and an old version cannot smuggle a seventh service.
OLD_IMAGE_MANIFEST="${TEST_ROOT}/old-image-manifest.json"
jq '.releaseVersion = "1.0.2" | .images |= map(select(.service != "mcp")
  | .reference |= sub(":[^:]+-"; ":1.0.2-"))' \
  "${PACKAGE_ROOT}/opt/myscoutee/packaging/IMAGE-MANIFEST.json" > "$OLD_IMAGE_MANIFEST"
CURRENT_RELEASE_VERSION="1.0.2"
validate_image_manifest "$OLD_IMAGE_MANIFEST" || fail "legacy rollback manifest was rejected"
CURRENT_RELEASE_VERSION="${PACKAGE_VERSION}"
jq --arg version "$PACKAGE_VERSION" '.releaseVersion = $version | .images |= map(.reference |= sub(":1.0.2"; ":" + $version))' \
  "$OLD_IMAGE_MANIFEST" > "$OLD_IMAGE_MANIFEST.tmp"
if validate_image_manifest "$OLD_IMAGE_MANIFEST.tmp"; then
  fail "MCP-less new release was accepted"
fi
CURRENT_RELEASE_VERSION=""

make_request() {
  local job_id="$1"
  local staged_artifact="$2"
  local request_file="$3"
  local artifact_size artifact_sha message_file signature_file signature

  artifact_size="$(stat -c '%s' "${staged_artifact}")"
  artifact_sha="sha256:$(sha256sum "${staged_artifact}" | awk '{ print $1 }')"
  message_file="${TEST_ROOT}/${job_id}-message"
  signature_file="${TEST_ROOT}/${job_id}-signature"
  printf '%s\n' \
    "myscoutee-release-package-v1" \
    "${PACKAGE_VERSION}" \
    "${PACKAGE_CHANNEL}" \
    "${artifact_size}" \
    "${artifact_sha}" > "${message_file}"
  openssl pkeyutl -sign -inkey "${PRIVATE_KEY}" -rawin \
    -in "${message_file}" -out "${signature_file}"
  signature="$(base64 -w 0 "${signature_file}")"

  jq -n \
    --arg jobId "${job_id}" \
    --arg releaseVersion "${PACKAGE_VERSION}" \
    --arg channel "${PACKAGE_CHANNEL}" \
    --arg artifactSha "${artifact_sha}" \
    --arg packageKeyId "${PACKAGE_KEY_ID}" \
    --arg packageSignature "${signature}" \
    --argjson artifactSize "${artifact_size}" \
    '{
      schema_version: 1,
      job_id: $jobId,
      requested_at: "2026-07-28T12:00:00Z",
      requested_by: "operator-packaging-test",
      manifest_hash: ("sha256:" + ("1" * 64)),
      release_version: $releaseVersion,
      channel: $channel,
      artifact_name: "myscoutee.deb",
      artifact_size_bytes: $artifactSize,
      artifact_sha256: $artifactSha,
      package_signing_key_id: $packageKeyId,
      package_signature: $packageSignature
    }' > "${request_file}"
}

run_request() {
  local request_file="$1"
  local claim

  claim="$(claim_request_entry "${request_file}")"
  process_claim "${claim}"
}

stage_request() {
  local job_id="$1"
  local request_file="${REQUEST_DIR}/${job_id}.json"
  local stage="${STAGING_DIR}/${job_id}"

  mkdir -p "${stage}"
  cp "${PACKAGE_PATH}" "${stage}/myscoutee.deb"
  make_request "${job_id}" "${stage}/myscoutee.deb" "${request_file}"
  printf '%s' "${request_file}"
}

SUCCESS_JOB="upd_0123456789abcdef0123456789abcdef"
SUCCESS_REQUEST="$(stage_request "${SUCCESS_JOB}")"
run_request "${SUCCESS_REQUEST}" || {
  cat "${JOBS_DIR}/${SUCCESS_JOB}/status.json" >&2
  fail "valid signed update was rejected"
}
SUCCESS_STATUS="${JOBS_DIR}/${SUCCESS_JOB}/status.json"
jq -e \
  --arg version "${PACKAGE_VERSION}" \
  '.phase == "COMPLETED"
    and .percent == 100
    and .targetVersion == $version
    and .backupPath == null' \
  "${SUCCESS_STATUS}" >/dev/null \
  || fail "completed status is incomplete"
[[ ! -e "${BACKUP_FILE}" ]] \
  || fail "update invoked a production backup instead of preserving data in place"
if jq -e 'select(.phase == "BACKING_UP")' \
  "${JOBS_DIR}/${SUCCESS_JOB}/events.ndjson" >/dev/null; then
  fail "update emitted an automatic backup phase"
fi
[[ "$(cat "${VERSION_FILE}")" == "${DEBIAN_PACKAGE_VERSION}" ]] \
  || fail "verified package was not passed to apt"
[[ "$(wc -l < "${APT_CALLS_FILE}")" == "1" ]] \
  || fail "valid update did not invoke apt exactly once"
[[ -s "${AUDIT_ROOT}/${SUCCESS_JOB}/request.json" ]] \
  || fail "accepted request was not copied to the durable audit directory"
jq -se '[.[].phase] == ["VERIFYING", "INSTALLING", "LOADING_IMAGES", "RESTARTING", "COMPLETED"]' \
  "${JOBS_DIR}/${SUCCESS_JOB}/events.ndjson" >/dev/null \
  || fail "update progress was not written as reconnectable events"
[[ "$(stat -c '%a' "${SUCCESS_STATUS}")" == "640" ]] \
  || fail "worker status is not group-readable"
[[ "$(stat -c '%g' "${SUCCESS_STATUS}")" == "${MYSCOUTEE_API_GROUP_ID}" ]] \
  || fail "worker status does not use the API group"

printf '%s\n' '1.0.0' > "${VERSION_FILE}"
TAMPER_JOB="upd_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
TAMPER_REQUEST="$(stage_request "${TAMPER_JOB}")"
printf '%s' tampered >> "${STAGING_DIR}/${TAMPER_JOB}/myscoutee.deb"
if run_request "${TAMPER_REQUEST}"; then
  fail "tampered package was accepted"
fi
jq -e '.phase == "FAILED" and .percent == 100' \
  "${JOBS_DIR}/${TAMPER_JOB}/status.json" >/dev/null \
  || fail "tampered package did not produce a durable failed status"
[[ "$(wc -l < "${APT_CALLS_FILE}")" == "1" ]] \
  || fail "tampered update reached apt"

SYMLINK_JOB="upd_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
SYMLINK_STAGE="${STAGING_DIR}/${SYMLINK_JOB}"
SYMLINK_REQUEST="${REQUEST_DIR}/${SYMLINK_JOB}.json"
mkdir -p "${SYMLINK_STAGE}"
ln -s "${PACKAGE_PATH}" "${SYMLINK_STAGE}/myscoutee.deb"
make_request "${SYMLINK_JOB}" "${PACKAGE_PATH}" "${SYMLINK_REQUEST}"
if run_request "${SYMLINK_REQUEST}"; then
  fail "symbolic-link artifact was accepted"
fi
jq -e '.phase == "FAILED"' "${JOBS_DIR}/${SYMLINK_JOB}/status.json" >/dev/null \
  || fail "symbolic-link artifact did not fail closed"

INTERMEDIATE_JOB="upd_cccccccccccccccccccccccccccccccc"
INTERMEDIATE_REQUEST="${REQUEST_DIR}/${INTERMEDIATE_JOB}.json"
ln -s "${TEST_ROOT}" "${STAGING_DIR}/${INTERMEDIATE_JOB}"
make_request "${INTERMEDIATE_JOB}" "${PACKAGE_PATH}" "${INTERMEDIATE_REQUEST}"
if run_request "${INTERMEDIATE_REQUEST}"; then
  fail "symbolic-link staging directory was accepted"
fi

OVERSIZED_REQUEST="${REQUEST_DIR}/oversized.json"
head -c 70000 /dev/zero > "${OVERSIZED_REQUEST}"
if run_request "${OVERSIZED_REQUEST}"; then
  fail "oversized request was accepted"
fi

DANGLING_REQUEST="${REQUEST_DIR}/dangling.json"
ln -s "${TEST_ROOT}/does-not-exist" "${DANGLING_REQUEST}"
if run_request "${DANGLING_REQUEST}"; then
  fail "dangling request symlink was accepted"
fi

DIRECTORY_REQUEST="${REQUEST_DIR}/directory.json"
mkdir "${DIRECTORY_REQUEST}"
if run_request "${DIRECTORY_REQUEST}"; then
  fail "request directory was accepted"
fi
FIFO_REQUEST="${REQUEST_DIR}/fifo.json"
mkfifo "${FIFO_REQUEST}"
if run_request "${FIFO_REQUEST}"; then
  fail "request FIFO was accepted"
fi
PREEXISTING_UNSAFE_CLAIM="${PROCESSING_DIR}/orphaned-claim"
ln -s "${TEST_ROOT}/does-not-exist" "${PREEXISTING_UNSAFE_CLAIM}"
if process_claim "${PREEXISTING_UNSAFE_CLAIM}"; then
  fail "unsafe preexisting claim was accepted"
fi
[[ -z "$(find "${PROCESSING_DIR}" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
  || fail "a claimed adversarial input remained in processing"
[[ "$(find "${REJECTED_DIR}" -mindepth 1 -maxdepth 1 | wc -l)" -ge 3 ]] \
  || fail "adversarial request entries were not durably quarantined"

CRASH_JOB="upd_dddddddddddddddddddddddddddddddd"
CRASH_REQUEST="$(stage_request "${CRASH_JOB}")"
read_request "${CRASH_REQUEST}" || fail "crash fixture request is invalid"
prepare_job_context || fail "crash fixture job could not be prepared"
CURRENT_VERSION="1.0.0"
write_status "INSTALLING" 85 "Simulated interrupted install."
printf '%s\n' "${DEBIAN_PACKAGE_VERSION}" > "${VERSION_FILE}"
cp "${PACKAGE_ROOT}/opt/myscoutee/packaging/IMAGE-MANIFEST.json" \
  "${INSTALLED_MANIFEST}"
if ! run_request "${CRASH_REQUEST}"; then
  fail "installed interrupted update was not reconciled"
fi
jq -e '.phase == "COMPLETED"' \
  "${JOBS_DIR}/${CRASH_JOB}/status.json" >/dev/null \
  || fail "reconciled update did not become completed"
[[ "$(wc -l < "${APT_CALLS_FILE}")" == "1" ]] \
  || fail "crash reconciliation retried apt"

RECOVERY_JOB="upd_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
printf '%s\n' '1.0.0' > "${VERSION_FILE}"
RECOVERY_REQUEST="$(stage_request "${RECOVERY_JOB}")"
read_request "${RECOVERY_REQUEST}" || fail "recovery fixture request is invalid"
prepare_job_context || fail "recovery fixture job could not be prepared"
CURRENT_VERSION="1.0.0"
write_status "INSTALLING" 85 "Simulated ambiguous install."
if run_request "${RECOVERY_REQUEST}"; then
  fail "ambiguous interrupted update reported success"
fi
jq -e '.phase == "RECOVERY_REQUIRED"' \
  "${JOBS_DIR}/${RECOVERY_JOB}/status.json" >/dev/null \
  || fail "ambiguous interrupted update was left nonterminal"
[[ "$(wc -l < "${APT_CALLS_FILE}")" == "1" ]] \
  || fail "ambiguous crash reconciliation retried apt"

BAD_IMAGE_JOB="upd_ffffffffffffffffffffffffffffffff"
BAD_IMAGE_REQUEST="$(stage_request "${BAD_IMAGE_JOB}")"
export UPDATE_TEST_BAD_IMAGE=true
if run_request "${BAD_IMAGE_REQUEST}"; then
  fail "wrong running image content fingerprint was accepted"
fi
unset UPDATE_TEST_BAD_IMAGE
jq -e '.phase == "RECOVERY_REQUIRED"' \
  "${JOBS_DIR}/${BAD_IMAGE_JOB}/status.json" >/dev/null \
  || fail "wrong running image content did not require recovery"

mkdir -p \
  "${CACHE_JOBS_DIR}/upd_10000000000000000000000000000000" \
  "${CACHE_JOBS_DIR}/upd_20000000000000000000000000000000" \
  "${CACHE_JOBS_DIR}/upd_30000000000000000000000000000000"
touch -d '2026-07-28 00:00:01Z' \
  "${CACHE_JOBS_DIR}/upd_10000000000000000000000000000000"
touch -d '2026-07-28 00:00:02Z' \
  "${CACHE_JOBS_DIR}/upd_20000000000000000000000000000000"
touch -d '2026-07-28 00:00:03Z' \
  "${CACHE_JOBS_DIR}/upd_30000000000000000000000000000000"
prune_cache
[[ "$(find "${CACHE_JOBS_DIR}" -mindepth 1 -maxdepth 1 -type d | wc -l)" == "2" ]] \
  || fail "cache retention did not enforce its configured bound"

# A downgrade must bind the exact previous package to the installed source.
printf '%s\n' '1000.0.0' > "${VERSION_FILE}"
ROLLBACK_PARENT="upd_12345678901234567890123456789012"
ROLLBACK_JOB="upd_12345678901234567890123456789013"
ROLLBACK_REQUEST="$(stage_request "$ROLLBACK_JOB")"
jq --arg job "$ROLLBACK_PARENT" '. + {rollback_job_id:$job}' "$ROLLBACK_REQUEST" > "$TEST_ROOT/rollback.json"
mv "$TEST_ROOT/rollback.json" "$ROLLBACK_REQUEST"
ROLLBACK_HASH="$(jq -r .artifact_sha256 "$ROLLBACK_REQUEST")"
jq -n --arg job "$ROLLBACK_PARENT" --arg version "$PACKAGE_VERSION" --arg hash "$ROLLBACK_HASH" \
  '{jobId:$job,fromVersion:"1000.0.0",targetVersion:$version,artifactSha256:$hash}' \
  | write_root_receipt "$RUNTIME_DIR/recovery.json"
CURRENT_ROLLBACK_JOB="$ROLLBACK_PARENT"
CURRENT_VERSION='1000.0.0'
CURRENT_RELEASE_VERSION="$PACKAGE_VERSION"
CURRENT_ARTIFACT_SHA256='sha256:0000000000000000000000000000000000000000000000000000000000000000'
if validate_rollback_target; then fail 'rollback accepted a different artifact hash'; fi
CURRENT_ARTIFACT_SHA256="$ROLLBACK_HASH"
CURRENT_VERSION='1001.0.0'
if validate_rollback_target; then fail 'rollback accepted stale installed source version'; fi
CURRENT_VERSION='1000.0.0'
chmod 0660 "$RUNTIME_DIR/recovery.json"
if validate_rollback_target; then fail 'rollback accepted a writable receipt'; fi
chmod 0640 "$RUNTIME_DIR/recovery.json"
validate_rollback_target || fail 'valid exact rollback point rejected'
run_request "$ROLLBACK_REQUEST" || fail 'verified previous package rollback failed'
jq -e '.phase == "COMPLETED"' "$JOBS_DIR/$ROLLBACK_JOB/status.json" >/dev/null || fail 'rollback not completed'
[[ "$(tail -n1 "$APT_CALLS_FILE")" == *--allow-downgrades* ]] || fail 'explicit rollback did not permit downgrade'
[[ ! -e "$RUNTIME_DIR/recovery.json" ]] || fail 'completed rollback retained a reusable recovery point'
jq -e --arg hash "$ROLLBACK_HASH" '.artifactSha256 == $hash' "$RUNTIME_DIR/installed-package.json" >/dev/null || fail 'installed receipt did not follow rollback'

echo "update worker tests passed"
