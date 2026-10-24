#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/release-project.sh"
release_project_load "${SCRIPT_DIR}" "$(stat -c %u "${BASH_SOURCE[0]}")" || {
  echo 'The package-owned release project policy is missing or unsafe.' >&2; exit 1;
}
migration_directory="${SCRIPT_DIR}/../migrations"
if [[ "$RELEASE_PROJECT_POLICY" != "${SCRIPT_DIR}/release-project.json" ]]; then
  migration_directory="$(dirname -- "$RELEASE_PROJECT_POLICY")/migrations"
fi
database="${MYSCOUTEE_MIGRATION_DATABASE:-production_db}"
case "$database" in production_db|demo_db) ;; *) echo 'Unsupported migration database.' >&2; exit 1;; esac
exec 9>/run/lock/${RELEASE_PROJECT_NAME}-data-migrations.lock
flock -n 9 || { echo 'Another data migration is running.' >&2; exit 1; }
media_manifest="$(jq -r '.partialData.mediaManifest // empty' "${SCRIPT_DIR}/migration-settings.json")"
media_manifest="${migration_directory}/${media_manifest}"
media_directory="${MYSCOUTEE_MIGRATION_MEDIA_DIRECTORY:-${SCRIPT_DIR}/../../server/docker/conf/minio/media}"
if [[ -f "$media_manifest" ]]; then
 python3 "$SCRIPT_DIR/migrate-seeded-media.py" check-inputs "$media_manifest" "$media_directory"
 # On a cold start Mongo is prepared before this runner; MinIO is needed too.
 # Partial releases use their already-running, matched MinIO image.
 if [[ "${MYSCOUTEE_MIGRATION_PREPARE_MINIO:-true}" == true ]]; then
  "${MYSCOUTEE_COMPOSE_SCRIPT:-${SCRIPT_DIR}/myscoutee-compose.sh}" up -d --wait --wait-timeout 180 minio
 fi
 python3 "$SCRIPT_DIR/migrate-seeded-media.py" prepare "$media_manifest" "$media_directory"
fi
directory="/tmp/${RELEASE_PROJECT_NAME}-migrations-$$"
trap 'docker exec mongodb rm -rf "$directory" >/dev/null' EXIT
docker cp "$migration_directory" "mongodb:$directory"
docker cp "${SCRIPT_DIR}/release-system-seeds.json" "mongodb:$directory/release-system-seeds.json"
for script in run-data-migrations.js sync-release-system-seeds.js; do
 docker exec -i -e "MYSCOUTEE_MIGRATION_DIRECTORY=$directory" \
  -e "MYSCOUTEE_MIGRATION_SEED_DIRECTORY=${MYSCOUTEE_MIGRATION_SEED_DIRECTORY:-/docker-entrypoint-initdb.d/myscoutee_db}" \
  mongodb sh -c 'exec mongosh --quiet --username "$MONGO_INITDB_ROOT_USERNAME" \
    --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin "$1" --file /dev/stdin' qa "$database" \
  < "${SCRIPT_DIR}/$script"
done
if [[ -f "$media_manifest" && "${MYSCOUTEE_MIGRATION_MEDIA_RETIRE:-true}" == true ]]; then
 python3 "$SCRIPT_DIR/migrate-seeded-media.py" retire "$media_manifest" "$media_directory"
fi
