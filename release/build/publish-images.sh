#!/usr/bin/env bash
# Publish only the versioned inventory built by build-production.sh.
# Authentication is provided by the caller (for CI, its repository GITHUB_TOKEN).
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}"
source "${SCRIPT_DIR}/../lib/release-config.sh"
release_config_load "${REPO_ROOT}"
VERSION="${MYSCOUTEE_VERSION:?Set the exact release version}"
OWNER="${GITHUB_REPOSITORY_OWNER:?Set the GitHub package owner}"
OWNER="${OWNER,,}"
[[ "$OWNER" =~ ^[a-z0-9][a-z0-9-]{0,38}$ ]] || exit 1
source "${SCRIPT_DIR}/../lib/release-project.sh"
release_project_load "${REPO_ROOT}/config/packaging" "$(id -u)"
inventory="$(release_project_images "$VERSION")"
destination="${MYSCOUTEE_DIST_DIR:-${REPO_ROOT}/build/packaging/dist}"
mkdir -p -- "$destination"
temporary="$(mktemp "${destination}/.published-images.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT

# Check the whole local set before publishing its first member.
while IFS= read -r reference; do
  docker image inspect "$reference" >/dev/null
done < <(jq -r '.[].reference' <<< "$inventory")
while IFS=$'\t' read -r service reference; do
  target="$(release_config_value .build.publishRegistry)/${OWNER}/${reference}"
  image_id="$(docker image inspect --format '{{.Id}}' "$reference")"
  [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 1
  docker tag "$reference" "$target"
  docker push "$target"
  # Pull the exact published tag, then prove it resolves to the built config.
  docker pull "$target" >/dev/null
  [[ "$(docker image inspect --format '{{.Id}}' "$target")" == "$image_id" ]] || {
    echo "Published image changed during verification: ${target}" >&2; exit 1;
  }
  digest="$(docker image inspect --format '{{json .RepoDigests}}' "$target" \
    | jq -r --arg prefix "${target%:*}@" '.[] | select(startswith($prefix))')"
  [[ "$digest" =~ @sha256:[0-9a-f]{64}$ ]] || exit 1
  jq -n -c --arg service "$service" --arg reference "$target" \
    --arg imageId "$image_id" --arg digest "$digest" \
    '{service:$service,reference:$reference,imageId:$imageId,digest:$digest}' >> "$temporary"
done < <(jq -r '.[] | [.service,.reference] | @tsv' <<< "$inventory")
jq -s --arg version "$VERSION" '{version:$version,images:.}' "$temporary" \
  > "${destination}/published-images.json"
echo "Published and pulled the exact managed image inventory for ${VERSION}."
