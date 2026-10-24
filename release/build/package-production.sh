#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}"
source "${SCRIPT_DIR}/../lib/release-config.sh"
release_config_load "${REPO_ROOT}"
SERVER_DIR="${REPO_ROOT}/server"
DIST_DIR="${MYSCOUTEE_DIST_DIR:-${REPO_ROOT}/build/packaging/dist}"
STAGING_DIR="${DIST_DIR}/deb-root"

read_version() {
  sed -n 's/^MYSCOUTEE_VERSION=//p' "${SERVER_DIR}/.env" | head -n 1
}

VERSION="${MYSCOUTEE_VERSION:-$(read_version)}"
VERSION="${VERSION:-$(release_config_value .build.fallbackVersion)}"
ARCHITECTURE="${DEB_ARCHITECTURE:-$(release_config_value .build.architecture)}"
DEBIAN_VERSION="${VERSION/-/\~}"
if [[ ! "${VERSION}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-qa\.[1-9][0-9]*)?$ ]] \
  || ! dpkg --validate-version "${DEBIAN_VERSION}" >/dev/null 2>&1; then
  echo "MYSCOUTEE_VERSION must be a SemVer core or QA prerelease such as 1.0.0-qa.1." >&2
  exit 1
fi
if [[ ! "${ARCHITECTURE}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; then
  echo "DEB_ARCHITECTURE is invalid." >&2
  exit 1
fi
export MYSCOUTEE_VERSION="${VERSION}"
source "${SCRIPT_DIR}/../lib/release-project.sh"
release_project_load "${REPO_ROOT}/config/packaging" "$(id -u)" || {
  echo 'Invalid release project policy.' >&2; exit 1;
}
release_project_export_images "${VERSION}" true
PACKAGE_NAME="${RELEASE_PROJECT_NAME}_${VERSION}_${ARCHITECTURE}"
DEB_PATH="${DIST_DIR}/${PACKAGE_NAME}.deb"
DEB_PARTIAL_PATH="${DIST_DIR}/${PACKAGE_NAME}.partial.deb"
CLIENT_TOOLS_ARCHIVE="${DIST_DIR}/${RELEASE_PROJECT_NAME}-client-tools_${VERSION}.tar.gz"
IMAGE_FINGERPRINT_HELPER="${SCRIPT_DIR}/../lib/image-content-fingerprint.sh"

if [[ "${BUILD_ARTIFACTS:-true}" == "true" ]]; then
  bash "${SCRIPT_DIR}/build-production.sh"
fi

rm -rf "${STAGING_DIR}" "${DEB_PARTIAL_PATH}"
install -d "${STAGING_DIR}/DEBIAN"
install -d "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/server/docker/conf"
install -d "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/server/docker/scripts"
install -d "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/server/projects/profile/secrets"
install -d "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging"
install -d "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/update"
install -d "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/images"
install -d "${STAGING_DIR}/lib/systemd/system"
install -d "${STAGING_DIR}/usr/share/${RELEASE_PROJECT_NAME}"

python3 "${SCRIPT_DIR}/render-debian.py" \
  "${REPO_ROOT}/packaging" "${STAGING_DIR}/DEBIAN" --hook all \
  --version "${DEBIAN_VERSION}" --architecture "${ARCHITECTURE}"

sed 's/docker-compose.production-replicaset.yml/docker-compose.replicaset.yml/g' \
  "${REPO_ROOT}/config/packaging/compose/docker-compose.production.yml" > "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/server/docker-compose-prod.yml"
chmod 0644 "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/server/docker-compose-prod.yml"
install -m 0644 "${REPO_ROOT}/config/packaging/compose/docker-compose.production-replicaset.yml" "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/server/docker-compose.replicaset.yml"
install -m 0644 "${SERVER_DIR}/docker-compose-stun.yml" "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/server/docker-compose-stun.yml"
install -m 0644 "${SERVER_DIR}/projects/profile/secrets/README.md" "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/server/projects/profile/secrets/README.md"
install -m 0644 "${SERVER_DIR}/projects/profile/secrets/firebase-service-account.json.example" "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/server/projects/profile/secrets/firebase-service-account.json.example"
# Credentials are deployment input, never package content. The operator
# provisions the real service-account file after installation through the
# protected deployment configuration path.

stage_mongo_configuration() {
  local source_root="${SERVER_DIR}/docker/conf/mongodb"
  local target_root="${STAGING_DIR}${RELEASE_PROJECT_ROOT}/server/docker/conf/mongodb"
  local demo_source="${source_root}/$(release_config_value .mongo.demoSeedDirectory)"
  local demo_target="${target_root}/$(release_config_value .mongo.demoSeedDirectory)"
  local production_source="${source_root}/$(release_config_value .mongo.productionSeedDirectory)"
  local production_target="${target_root}/$(release_config_value .mongo.productionSeedDirectory)"
  local seed_rule collection source_file demo_file demo_admin_emails
  local production_identity_seed
  local -a production_collections=()

  install -d "${target_root}" "${demo_target}" "${production_target}"

  # Only the Mongo initializer itself is shared. Development/E2E databases and
  # runtime user collections are not release-package input.
  while IFS= read -r source_file; do
    install -m 0644 "${source_file}" "${target_root}/$(basename "${source_file}")"
  done < <(find "${source_root}" -maxdepth 1 -type f | sort)
  chmod 0755 "${target_root}/mongo_import.sh"

  for production_identity_seed in \
    "${production_source}/adminUsers.json" \
    "${production_source}/users.json"; do
    if [[ -e "${production_identity_seed}" ]] && ! jq -e 'type == "array" and length == 0' \
        "${production_identity_seed}" >/dev/null; then
      echo "Production identity seeds must remain empty; operators are provisioned after installation." >&2
      exit 1
    fi
  done

  # The bundled Explore database is isolated demo state. Derive its admin
  # allow-list only from explicitly synthetic demo users, never from a
  # developer/vendor address present in a source checkout.
  demo_admin_emails="$(
    jq -c '
      [
        .[]
        | select(.hostTier == "Admin")
        | (.email // "")
        | select(test("@[^@]+\\.(local|invalid)$"; "i"))
      ]
      | unique
    ' "${demo_source}/users.json"
  )"
  if ! jq -e 'type == "array" and length > 0' \
      <<< "${demo_admin_emails}" >/dev/null; then
    echo "Explore seed has no explicitly synthetic demo administrators." >&2
    exit 1
  fi
  while IFS= read -r demo_file; do
    if [[ "$(basename "${demo_file}")" == "appSettings.json" ]]; then
      jq --argjson adminEmails "${demo_admin_emails}" '
        map(
          if .settingsKey == "global"
          then .adminEmails = $adminEmails
          else .
          end
        )
      ' "${demo_file}" > "${demo_target}/appSettings.json"
    else
      install -m 0644 "${demo_file}" "${demo_target}/$(basename "${demo_file}")"
    fi
  done < <(find "${demo_source}" -maxdepth 1 -type f -name '*.json' | sort)

  # The production database receives only the system/configuration collections
  # declared in the packaged allow-list. In particular, users, adminUsers,
  # activity, chat, payment, and other deployment/runtime records are absent
  # from the .deb even though a developer checkout may contain fixtures.
  seed_rule="$(
    sed -n 's/^MONGO_IMPORT_ALLOWED_COLLECTIONS_BY_DB=//p' \
      "${REPO_ROOT}/config/packaging/templates/${RELEASE_PROJECT_NAME}.env" \
      | tr ';' '\n' \
      | sed -n "s/^$(release_config_value .mongo.productionDatabase)://p" \
      | tail -n 1
  )"
  if [[ -z "${seed_rule}" || "${seed_rule}" == *"*"* ]]; then
    echo "Production Mongo seed allow-list must be explicit and non-empty." >&2
    exit 1
  fi
  IFS=',' read -r -a production_collections <<< "${seed_rule}"
  for collection in "${production_collections[@]}"; do
    if [[ ! "${collection}" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
      echo "Invalid production seed collection: ${collection}" >&2
      exit 1
    fi
    source_file="${production_source}/${collection}.json"
    if [[ ! -f "${source_file}" ]]; then
      echo "Missing production system seed: ${source_file}" >&2
      exit 1
    fi
    if [[ "${collection}" == "appSettings" ]]; then
      # Admin authorization is mutable deployment state configured by the
      # authenticated operator. A release never nominates an administrator.
      jq '
        map(
          if .settingsKey == "global"
          then .adminEmails = []
          else .
          end
        )
      ' "${source_file}" > "${production_target}/appSettings.json"
    else
      install -m 0644 "${source_file}" "${production_target}/${collection}.json"
    fi
  done
}

python3 "${SCRIPT_DIR}/../audit/check-seed-parity.py" --project-root "${REPO_ROOT}"
node "${REPO_ROOT}/frontend/scripts/audit-i18n-mongo-seed.js"
stage_mongo_configuration
python3 "${SCRIPT_DIR}/../audit/check-seed-parity.py" --project-root "${REPO_ROOT}" \
  --packaged-root "${STAGING_DIR}${RELEASE_PROJECT_ROOT}"
# Host runtime scripts are project-selected build inputs. Dev/E2E helpers can
# remain in the source tree without becoming installed host commands.
runtime_manifest="${REPO_ROOT}/config/packaging/release/runtime-scripts.json"
jq -e 'type=="array" and length==(unique|length)
  and all(.[]; type=="string" and test("^[A-Za-z][A-Za-z0-9_.-]*$"))' "$runtime_manifest" >/dev/null
while IFS= read -r runtime_name; do
  runtime_script_path="${SERVER_DIR}/docker/scripts/${runtime_name}"
  [[ -e "$runtime_script_path" && ! -L "$runtime_script_path" ]] || {
    echo "Selected host runtime script is missing or symbolic: ${runtime_name}" >&2; exit 1;
  }
  cp -a "$runtime_script_path" "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/server/docker/scripts/"
done < <(jq -r '.[]' "$runtime_manifest")
# Only deployment-host runtime scripts are installed. Everything in
# packaging/release and repository developer helpers stays source-only.
install -d "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/scripts"
python3 "${SCRIPT_DIR}/stage-runtime.py" "${REPO_ROOT}" "${REPO_ROOT}/build/scripts"
python3 "${SCRIPT_DIR}/stage-runtime.py" "${REPO_ROOT}" "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/scripts"
install -m 0644 "$RELEASE_PROJECT_POLICY" "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/scripts/release-project.json"
cp -a "${REPO_ROOT}/config/packaging/migrations" "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/"
if jq -e '.partialData.mediaManifest != null' <<< "$RELEASE_SETTINGS" >/dev/null; then
# The host migration must have its replacement bytes before Mongo references
# change, including upgrades from an older MinIO image.
media_manifest="${REPO_ROOT}/config/packaging/migrations/$(release_config_value .partialData.mediaManifest)"
media_source="${SERVER_DIR}/docker/conf/minio/media"
python3 "${REPO_ROOT}/build/scripts/migrate-seeded-media.py" check-inputs "$media_manifest" "$media_source"
while IFS= read -r key; do
  install -D -m 0644 "$media_source/$key" "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/server/docker/conf/minio/media/$key"
done < <(jq -r '.minio[].key' "$media_manifest")
fi
python3 "${SCRIPT_DIR}/render-debian.py" "${REPO_ROOT}/packaging" \
  "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/templates" --component templates
python3 "${SCRIPT_DIR}/render-debian.py" "${REPO_ROOT}/packaging" \
  "${STAGING_DIR}/lib/systemd/system" --component systemd
python3 "${SCRIPT_DIR}/render-debian.py" "${REPO_ROOT}/packaging" \
  "${STAGING_DIR}/usr/lib/sysusers.d" --component sysusers
install -m 0644 "${REPO_ROOT}/config/packaging/templates/update-release-key.README" "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/update/README"
printf '%s\n' "${VERSION}" > "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/VERSION"

sed -i "s/^MYSCOUTEE_VERSION=.*/MYSCOUTEE_VERSION=${VERSION}/" \
  "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/templates/${RELEASE_PROJECT_NAME}.env"
while IFS=$'\t' read -r name reference; do
  sed -i "s/^${name}=.*/${name}=${reference}/" \
    "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/templates/${RELEASE_PROJECT_NAME}.env"
done < <(release_project_images "${VERSION}" | jq -r '.[] | [.environment,.reference] | @tsv')

save_image() {
  local image_name="$1"
  local archive_name="$2"
  local pull_if_missing="${3:-false}"

  if ! docker image inspect "${image_name}" >/dev/null 2>&1; then
    if [[ "${pull_if_missing}" == "true" ]]; then
      docker pull "${image_name}"
    fi
  fi

  if ! docker image inspect "${image_name}" >/dev/null 2>&1; then
    echo "Missing Docker image: ${image_name}" >&2
    echo "Run with BUILD_ARTIFACTS=true or build the image before packaging." >&2
    exit 1
  fi

  docker save -o "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/images/${archive_name}.tar" "${image_name}"
}

image_id() {
  local image_name="$1"
  local value

  value="$(docker image inspect --format '{{.Id}}' "${image_name}")"
  if [[ ! "${value}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "Docker returned an invalid image ID for ${image_name}." >&2
    exit 1
  fi
  printf '%s' "${value}"
}

image_content_fingerprint() {
  local image_name="$1"
  local value

  value="$(bash "${IMAGE_FINGERPRINT_HELPER}" docker "${image_name}")"
  if [[ ! "${value}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "Could not fingerprint Docker image ${image_name}." >&2
    exit 1
  fi
  printf '%s' "${value}"
}

if [[ "${PACKAGE_IMAGES:-true}" == "true" ]]; then
  image_rows="$(release_project_images "${VERSION}")"
  manifest_rows="${DIST_DIR}/.image-manifest-rows.jsonl"
  : > "${manifest_rows}"
  while IFS= read -r image_row; do
    reference="$(jq -r '.reference' <<< "${image_row}")"
    save_image "${reference}" "${reference/:/-}"
    jq --arg imageId "$(image_id "${reference}")" \
      --arg fingerprint "$(image_content_fingerprint "${reference}")" \
      -c '{service,container,reference,imageId:$imageId,contentFingerprint:$fingerprint}' \
      <<< "${image_row}" >> "${manifest_rows}"
  done < <(jq -c '.[]' <<< "${image_rows}")
  jq -s --arg releaseVersion "${VERSION}" \
    '{schemaVersion:1,releaseVersion:$releaseVersion,bundled:true,images:.}' \
    "${manifest_rows}" > "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/IMAGE-MANIFEST.json"
  rm -- "${manifest_rows}"
  release_project_validate_manifest "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/IMAGE-MANIFEST.json" "${VERSION}"
elif [[ "${ALLOW_UNBUNDLED_IMAGES_FOR_TESTS:-false}" == "true" ]]; then
  jq -n \
    --arg releaseVersion "${VERSION}" \
    '{
      schemaVersion: 1,
      releaseVersion: $releaseVersion,
      bundled: false,
      images: []
    }' > "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/IMAGE-MANIFEST.json"
else
  echo "Release packages must bundle their managed images." >&2
  echo "Set ALLOW_UNBUNDLED_IMAGES_FOR_TESTS=true only for package-content tests." >&2
  exit 1
fi

if [[ "${PACKAGE_OFFICIAL_IMAGES:-false}" == "true" ]]; then
  save_image "${MONGO_IMAGE:-$(release_official_image MONGO_IMAGE)}" "mongo" true
  save_image "${REDIS_IMAGE:-$(release_official_image REDIS_IMAGE)}" "redis" true
fi

if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "dpkg-deb is required to build the Debian package." >&2
  exit 1
fi

find "${STAGING_DIR}" -type d -exec chmod 0755 {} +
find "${STAGING_DIR}" -type f -exec chmod 0644 {} +
chmod 0755 \
  "${STAGING_DIR}/DEBIAN/preinst" \
  "${STAGING_DIR}/DEBIAN/postinst" \
  "${STAGING_DIR}/DEBIAN/prerm" \
  "${STAGING_DIR}/DEBIAN/postrm"
find "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/packaging/scripts" \
  -type f \( -name "*.sh" -o -name "*.py" \) -exec chmod 0755 {} +
find "${STAGING_DIR}${RELEASE_PROJECT_ROOT}/server/docker" \
  -type f -name "*.sh" -exec chmod 0755 {} +
# The same standalone builder is used for helper-only releases and full DEBs.
MYSCOUTEE_VERSION="${VERSION}" MYSCOUTEE_DIST_DIR="${DIST_DIR}" \
  node "${SCRIPT_DIR}/../../bin/packaging.mjs" --project-root "${REPO_ROOT}" client-tools

install -m 0644 \
  "${CLIENT_TOOLS_ARCHIVE}" \
  "${STAGING_DIR}/usr/share/${RELEASE_PROJECT_NAME}/$(basename "${CLIENT_TOOLS_ARCHIVE}")"

bash "${SCRIPT_DIR}/../audit/audit-package-credentials.sh" "${STAGING_DIR}"
input_checks=()
if [[ "${PACKAGE_IMAGES:-true}" == true ]]; then
  input_checks+=(--images)
fi
python3 "${SCRIPT_DIR}/../../tests/consumer/deployment/deployment-input-parity-test.py" \
  "${STAGING_DIR}" "${input_checks[@]}"

dpkg-deb --root-owner-group --build \
  "${STAGING_DIR}" \
  "${DEB_PARTIAL_PATH}"
dpkg-deb --info "${DEB_PARTIAL_PATH}" >/dev/null
mv -f "${DEB_PARTIAL_PATH}" "${DEB_PATH}"
chmod 0644 "${DEB_PATH}"
echo "Operator client tools: ${CLIENT_TOOLS_ARCHIVE}" >&2
echo "${DEB_PATH}"
