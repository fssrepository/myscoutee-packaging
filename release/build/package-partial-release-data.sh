#!/usr/bin/env bash
# Stage versioned data inputs for apply-partial-release-data.sh; no host changes.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: package-partial-release-data.sh NEW_OUTPUT_DIRECTORY' >&2; exit 1; }
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}"
source "$script_directory/../lib/release-config.sh"
release_config_load "$repository"
python3 "$script_directory/stage-runtime.py" "$repository" "$repository/build/scripts"
output="$1"
[[ ! -e "$output" ]] || { echo 'Output must not already exist.' >&2; exit 1; }
python3 "$script_directory/../audit/check-seed-parity.py" --project-root "$repository"
node "$repository/frontend/scripts/audit-i18n-mongo-seed.js"
manifest="$repository/config/packaging/migrations/$(release_config_value .partialData.mediaManifest)"
media="$repository/server/docker/conf/minio/media"
python3 "$repository/build/scripts/migrate-seeded-media.py" check-inputs "$manifest" "$media"
mkdir -p "$output/scripts" "$output/seeds/production_db" "$output/seeds/demo_db"
cp -a "$repository/config/packaging/migrations" "$output/migrations"
mapfile -t runtime_scripts < <(release_config_value '.partialData.scripts[]')
for name in "${runtime_scripts[@]}"; do
 install -m 0644 "$repository/build/scripts/$name" "$output/scripts/$name"
done
release_config_value .partialData > "$output/partial-data.json"
install -m 0644 "$repository/config/packaging/release-project.json" "$output/scripts/release-project.json"
install -m 0755 "$script_directory/../apply-partial-release-data.sh" "$output/apply-partial-release-data.sh"
mapfile -t names < <(jq -r --slurpfile policy "$output/partial-data.json" '[.[].collection] + $policy[0].catalogCollections | unique[]' "$repository/build/scripts/release-system-seeds.json")
mapfile -t databases < <(release_config_value '.partialData.databases[].name')
for database in "${databases[@]}"; do
 source_database="$(jq -r --arg database "$database" '.partialData.databases[] | select(.name == $database) | .source' <<< "$RELEASE_SETTINGS")"
 for name in "${names[@]}"; do
  install -m 0644 "$repository/server/docker/conf/mongodb/$source_database/$name.json" "$output/seeds/$database/$name.json"
 done
done
mapfile -t demo_names < <(release_config_value '.partialData.demoCollections[]')
for name in "${demo_names[@]}"; do
 install -m 0644 "$repository/server/docker/conf/mongodb/demo_db/$name.json" "$output/seeds/demo_db/$name.json"
done
while IFS= read -r key; do
 install -D -m 0644 "$media/$key" "$output/media/$key"
done < <(jq -r '.minio[].key' "$manifest")
(cd "$output" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
echo "Partial release data staged: $output"
