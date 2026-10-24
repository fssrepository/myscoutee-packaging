#!/usr/bin/env bash
# Versioned data prerequisites for an explicitly selected container-only update.
# No DEB installation, demo reset or user-content replacement.
set -euo pipefail
[[ $(id -u) == 0 && $# == 1 ]] || { echo 'Run as root with the extracted release input directory.' >&2; exit 1; }
release=$(realpath "$1")
policy="$release/partial-data.json"
mongo_container="$(jq -er .mongoContainer "$policy")"
package_name="$(jq -er .packageName "$release/scripts/release-project.json")"
[[ "$package_name" =~ ^[a-z][a-z0-9-]{1,63}$ ]] || exit 1
package_root="/opt/${package_name}"
server="$package_root/server"
package="$package_root/packaging"
required_migration="$(jq -er .requiredMigration "$policy")"
mapfile -t databases < <(jq -er '.databases[].name' "$policy")
mapfile -t demo_names < <(jq -er '.demoCollections[]' "$policy")
[[ -f "$release/migrations/$required_migration" && -f "$server/docker-compose-prod.yml" ]] || exit 1
# Use the same selection as the shared synchronizer, plus migration-owned catalogs.
# Validate the complete input set before any package backup or database mutation.
seed_selection="$(jq -er --slurpfile policy "$policy" '[.[].collection] + $policy[0].catalogCollections | unique[]' "$release/scripts/release-system-seeds.json")"
mapfile -t seed_names <<< "$seed_selection"
for database in "${databases[@]}"; do
 for name in "${seed_names[@]}"; do
  [[ -f "$release/seeds/$database/$name.json" && ! -L "$release/seeds/$database/$name.json" ]] || exit 1
 done
done
for name in "${demo_names[@]}"; do
 [[ -f "$release/seeds/demo_db/$name.json" && ! -L "$release/seeds/demo_db/$name.json" ]] || exit 1
done
if jq -e '.scripts | index("migration-settings.json") != null' "$policy" >/dev/null; then
 [[ -f "$release/scripts/migration-settings.json" && ! -L "$release/scripts/migration-settings.json" ]] || exit 1
 jq -e --arg manifest "$(jq -er .mediaManifest "$policy")" \
  '.schemaVersion == 1 and .partialData.mediaManifest == $manifest' \
  "$release/scripts/migration-settings.json" >/dev/null || exit 1
fi
media_manifest="$release/migrations/$(jq -er .mediaManifest "$policy")"
if [[ -f "$media_manifest" ]]; then
 [[ -f "$release/scripts/migrate-seeded-media.py" && ! -L "$release/scripts/migrate-seeded-media.py" ]] || exit 1
 python3 "$release/scripts/migrate-seeded-media.py" check-inputs "$media_manifest" "$release/media"
fi
# Preserve the small package-owned input set, independently of live Mongo data.
if [[ ! -f "$release/previous-package-data.tar" ]]; then
 backup_paths=(packaging/migrations packaging/scripts/migrate-production-data.sh)
 if [[ -f "$package/scripts/migration-settings.json" ]]; then
  backup_paths+=(packaging/scripts/migration-settings.json)
 fi
 for database in "${databases[@]}"; do
  directory="$(jq -er --arg database "$database" '.databases[] | select(.name == $database) | .source' "$policy")"
  backup_paths+=("server/docker/conf/mongodb/$directory")
 done
 tar -C "$package_root" -cf "$release/previous-package-data.tar" "${backup_paths[@]}"
 chmod 0600 "$release/previous-package-data.tar"
fi
if [[ -f "$media_manifest" ]]; then
 # An old scheduler could recreate PNG references after migration023 has its
 # receipt. The existing partial service updater installs the matching API next.
 api_service="$(jq -er .apiService "$policy")"
 api_container="$(jq -er --arg service "$api_service" '.images[] | select(.service == $service) | .container' "$release/scripts/release-project.json")"
 [[ "$(docker inspect --format '{{.State.Running}}' "$api_container")" == false ]] || {
  echo 'Stop profilemanagement with the installed Compose helper before applying the media release data.' >&2
  exit 1
 }
fi
seed_directory="$(docker exec "$mongo_container" mktemp -d /tmp/myscoutee-release-seeds.XXXXXX)"
trap 'docker exec "$mongo_container" rm -rf "$seed_directory" >/dev/null' EXIT
docker cp "$release/seeds/." "$mongo_container:$seed_directory"
for database in "${databases[@]}"; do
 MYSCOUTEE_MIGRATION_DATABASE="$database" \
 MYSCOUTEE_MIGRATION_SEED_DIRECTORY="$seed_directory/$database" \
 MYSCOUTEE_MIGRATION_MEDIA_DIRECTORY="$release/media" \
 MYSCOUTEE_MIGRATION_MEDIA_RETIRE=false MYSCOUTEE_MIGRATION_PREPARE_MINIO=false \
  bash "$release/scripts/migrate-production-data.sh"
 directory="$(jq -er --arg database "$database" '.databases[] | select(.name == $database) | .source' "$policy")"
 for name in "${seed_names[@]}"; do
  install -m 0644 "$release/seeds/$database/$name.json" "$server/docker/conf/mongodb/$directory/$name.json"
 done
done
for name in "${demo_names[@]}"; do
 install -m 0644 "$release/seeds/demo_db/$name.json" "$server/docker/conf/mongodb/demo_db/$name.json"
done
if [[ -f "$media_manifest" ]]; then
 python3 "$release/scripts/migrate-seeded-media.py" retire "$media_manifest" "$release/media"
 while IFS= read -r key; do
  install -D -m 0644 "$release/media/$key" "$server/docker/conf/minio/media/$key"
 done < <(jq -r '.minio[].key' "$media_manifest")
 install -m 0755 "$release/scripts/migrate-seeded-media.py" "$package/scripts/migrate-seeded-media.py"
fi
# Existing systemd startup must recognize schema5 on later service restarts.
for source in "$release"/migrations/*.js; do install -m 0644 "$source" "$package/migrations/$(basename "$source")"; done
if [[ -d "$release/migrations/seeds" ]]; then
 while IFS= read -r -d '' source; do
  install -D -m 0644 "$source" "$package/migrations/seeds/${source#"$release/migrations/seeds/"}"
 done < <(find "$release/migrations/seeds" -type f -name '*.json' -print0)
fi
mapfile -t installed_scripts < <(jq -er '.installedScripts[]' "$policy")
for name in "${installed_scripts[@]}"; do
 mode=0755
 [[ "$name" != *.json ]] || mode=0644
 install -m "$mode" "$release/scripts/$name" "$package/scripts/$name"
done
install -m 0644 "$release/scripts/release-system-seeds.json" "$package/scripts/release-system-seeds.json"
# Keep the installed startup order consistent: Mongo readiness, schema, seeds.
unit="/lib/systemd/system/${package_name}.service"
startup_script="$(jq -er .startupScript "$policy")"
startup_arguments="$(jq -er .startupArguments "$policy")"
if [[ -f "$unit" ]] && grep -q "^ExecStartPre=$package/scripts/$startup_script\$" "$unit"; then
 [[ -f "$release/previous-${package_name}.service" ]] || cp -p "$unit" "$release/previous-${package_name}.service"
 sed -i "s@^ExecStartPre=$package/scripts/$startup_script\$@ExecStartPre=$package/scripts/$startup_script $startup_arguments@" "$unit"
 systemctl daemon-reload
fi
echo 'Partial-update data prerequisites complete; user collections and installed DEB retained.'
