#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${NGINX_CONTAINER:-nginx}"
HTML_DIR="${NGINX_HTML_DIR:-/usr/share/nginx/html}"
INDEX_PATH="${HTML_DIR%/}/index.html"
ACTION="${1:-apply}"
MARKER_START="myscoutee-facebook-coming-soon-patch:start"
MARKER_END="myscoutee-facebook-coming-soon-patch:end"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [apply|remove]

Patches the running MyScoutee nginx container so Facebook login is shown as
"Coming soon" without rebuilding or reinstalling the deb package.

Environment:
  NGINX_CONTAINER  Container name. Default: nginx
  NGINX_HTML_DIR   Static html dir in the container. Default: /usr/share/nginx/html
USAGE
}

if [[ "${ACTION}" == "-h" || "${ACTION}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${ACTION}" != "apply" && "${ACTION}" != "remove" ]]; then
  usage >&2
  exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required on this VPS." >&2
  exit 1
fi

if [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null || true)" != "true" ]]; then
  echo "Container '${CONTAINER}' is not running. Set NGINX_CONTAINER if your nginx container has another name." >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

index_file="${tmp_dir}/index.html"
patched_file="${tmp_dir}/index.patched.html"
patch_block="${tmp_dir}/facebook-coming-soon-block.html"
backup_file="${BACKUP_DIR:-/tmp}/myscoutee-nginx-index.html.backup.$(date +%Y%m%d%H%M%S)"

docker cp "${CONTAINER}:${INDEX_PATH}" "${index_file}"
cp "${index_file}" "${backup_file}"

if [[ "${ACTION}" == "remove" ]]; then
  if ! grep -q "${MARKER_START}" "${index_file}"; then
    echo "Facebook coming-soon patch is not present in ${CONTAINER}:${INDEX_PATH}."
    exit 0
  fi

  awk -v start="${MARKER_START}" -v end="${MARKER_END}" '
    index($0, start) { skipping = 1; next }
    index($0, end) { skipping = 0; next }
    !skipping { print }
  ' "${index_file}" > "${patched_file}"

  docker cp "${patched_file}" "${CONTAINER}:${INDEX_PATH}"
  docker exec "${CONTAINER}" nginx -s reload >/dev/null 2>&1 || true
  echo "Removed Facebook coming-soon patch from ${CONTAINER}:${INDEX_PATH}."
  exit 0
fi

if grep -q "${MARKER_START}" "${index_file}"; then
  echo "Facebook coming-soon patch is already present in ${CONTAINER}:${INDEX_PATH}."
  exit 0
fi

patch_input="${NGINX_FACEBOOK_PATCH_FILE:-$(dirname -- "${BASH_SOURCE[0]}")/facebook-coming-soon.html}"
[[ -f "$patch_input" && ! -L "$patch_input" ]] || { echo 'Missing Facebook patch input.' >&2; exit 1; }
cp -- "$patch_input" "$patch_block"

awk '
  FNR == NR {
    patch = patch $0 ORS
    next
  }
  /<\/body>/ && !inserted {
    printf "%s", patch
    inserted = 1
  }
  { print }
  END {
    if (!inserted) {
      printf "%s", patch
    }
  }
' "${patch_block}" "${index_file}" > "${patched_file}"

docker cp "${patched_file}" "${CONTAINER}:${INDEX_PATH}"
docker exec "${CONTAINER}" nginx -s reload >/dev/null 2>&1 || true

echo "Applied Facebook coming-soon patch to ${CONTAINER}:${INDEX_PATH}."
echo "A local backup was kept for this run at ${backup_file}."
