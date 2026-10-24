#!/usr/bin/env bash
set -euo pipefail
root="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:-$PWD}"
source "${root}/build/scripts/release-project.sh"
source "${root}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/client-tools/client-project.sh"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
install -m 0644 "${root}/config/packaging/release-project.json" "${temporary}/release-project.json"
release_project_load "$temporary" "$(id -u)"
case_config="$root/config/packaging/tests/release-project.json"
[[ "$RELEASE_PROJECT_UID:$RELEASE_PROJECT_GID" == "$(jq -er .identity "$case_config")" ]]
while IFS=$'\t' read -r version expected_count; do
 [[ "$(release_project_images "$version" | jq length)" == "$expected_count" ]]
done < <(jq -r '.imageCounts[] | [.version,.count] | @tsv' "$case_config")
release_project_client_load "$temporary" "$(id -u)"
while IFS= read -r expected; do
 actual="$(release_project_client_service "$(jq -r .name <<< "$expected")")"
 jq -e --argjson expected "$expected" 'all($expected | to_entries[]; . as $entry | $entry.value == ($actual[$entry.key]))' \
   --argjson actual "$actual" <<< '{}' >/dev/null
done < <(jq -c '.clientServices[]' "$case_config")
if release_project_client_service absent >/dev/null; then echo 'Accepted an unselected client service' >&2; exit 1; fi
for mutation in \
  '.clientTools.serverDirectory = "relative"' \
  '.clientTools.stateDirectory = "/var/lib/../other"' \
  '.clientTools.composeFiles += ["../other.yml"]' \
  '.clientTools.composeFiles += [.clientTools.composeFiles[0]]' \
  '.clientTools.services += [.clientTools.services[0]]' \
  '.clientTools.services[0].imageService = "absent"' \
  '.clientTools.services[0].imageService = "nginx-base"' \
  '.clientTools.services[0].container = "foreign"' \
  '.clientTools.services[2].environment = "INVALID;command"' \
  '.clientTools.services[2].sameUpstream = "false"' \
  '.clientTools.services[0].stateDirectory = "../other"' \
  '.clientTools.services[0].frontendVersionFile = "relative"' \
  '.clientTools.services[0].unknown = true'; do
  jq "$mutation" "${root}/config/packaging/release-project.json" > "${temporary}/release-project.json"
  if release_project_client_load "$temporary" "$(id -u)"; then
    echo "Accepted invalid client configuration: $mutation" >&2; exit 1
  fi
done
install -m 0644 "${root}/config/packaging/release-project.json" "${temporary}/release-project.json"

# A different product selects five existing framework images from its own
# installed policy. No Registry/payment image is required or accepted.
jq --arg repository_prefix "$(jq -r .repositoryPrefix "$case_config")" '.packageName = "sample-template" | .runtimeIdentity = {uid:10002,gid:10002} | .images |= map(
  select(.service != "registry-demo" and .service != "payment-simulator")
  | .repository |= sub("^" + $repository_prefix; "sample-template-")
  | .sinceVersion = "1.0.0")' "${temporary}/release-project.json" > "${temporary}/selected.json"
install -m 0644 "${temporary}/selected.json" "${temporary}/release-project.json"
release_project_load "$temporary" "$(id -u)"
[[ "$RELEASE_PROJECT_NAME" == sample-template && "$RELEASE_PROJECT_ROOT" == /opt/sample-template ]]
[[ "$RELEASE_PROJECT_UID:$RELEASE_PROJECT_GID" == 10002:10002 ]]
images="$(release_project_images 1.0.0)"
[[ "$(jq length <<< "$images")" == 5 ]]
release_project_export_images 1.0.0 true
[[ "$NGINX_BASE_IMAGE" == sample-template-nginx:1.0.0-base ]]
[[ "$MCP_IMAGE" == sample-template-mcp:1.0.0-prod ]]
if (NGINX_BASE_IMAGE=foreign:tag; release_project_export_images 1.0.0 true); then
  echo 'Accepted a release image override' >&2; exit 1
fi
(NGINX_BASE_IMAGE=local:test; release_project_export_images 1.0.0 false; [[ "$NGINX_BASE_IMAGE" == local:test ]])
jq -n --argjson images "$images" '{schemaVersion:1, releaseVersion:"1.0.0", bundled:true,
  images:[$images[] | {service,container,reference,
    imageId:("sha256:" + ("a" * 64)), contentFingerprint:("sha256:" + ("b" * 64))}]}' > "${temporary}/manifest.json"
release_project_validate_manifest "${temporary}/manifest.json" 1.0.0
for mutation in \
  '.images[0].reference = "foreign:1.0.0-prod"' \
  '.images[0].container = "foreign"' \
  '.images += [.images[0]]' \
  'del(.images[0].contentFingerprint)' \
  '.images[0].imageId = "sha256:wrong"' \
  '.images[0].unexpected = true' \
  '.releaseVersion = "1.0.1"' \
  '.bundled = false'; do
  jq "$mutation" "${temporary}/manifest.json" > "${temporary}/invalid.json"
  if release_project_validate_manifest "${temporary}/invalid.json" 1.0.0; then
    echo "Accepted invalid manifest: $mutation" >&2; exit 1
  fi
done
for mutation in \
  '.packageName = "../../outside"' \
  '.images += [.images[0]]' \
  '.images[0].repository = "foreign/path:tag"' \
  '.images[0].sinceVersion = "latest"' \
  '.runtimeIdentity.uid = 0' \
  '.runtimeIdentity.gid = 10002.5' \
  '.runtimeIdentity.uid = "10002"' \
  '.runtimeIdentity.other = 1' \
  '.unknown = true'; do
  jq "$mutation" "${temporary}/selected.json" > "${temporary}/release-project.json"
  if release_project_load "$temporary" "$(id -u)"; then
    echo "Accepted invalid installed policy: $mutation" >&2; exit 1
  fi
done
install -m 0666 "${temporary}/selected.json" "${temporary}/release-project.json"
if release_project_load "$temporary" "$(id -u)"; then echo 'Accepted writable policy' >&2; exit 1; fi
rm "${temporary}/release-project.json"
ln -s "${temporary}/selected.json" "${temporary}/release-project.json"
if release_project_load "$temporary" "$(id -u)"; then echo 'Accepted symlink policy' >&2; exit 1; fi
echo 'PASS native image history, minimal project inventory and 15 manifest/policy rejection cases'
