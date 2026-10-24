#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  printf 'nginx-image-contract-test: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repository_root="$(cd -- "$script_dir/../../.." && pwd -P)"
version="${MYSCOUTEE_VERSION:-$(sed -n '1p' "$repository_root/config/packaging/VERSION")}"
image="${REGISTRY_NGINX_PRODUCTION_IMAGE:-@@NGINX_IMAGE@@:${version}-prod}"
docker_bin="${DOCKER_BIN:-docker}"

command -v "$docker_bin" >/dev/null 2>&1 ||
  fail "Docker is unavailable"
"$docker_bin" image inspect "$image" >/dev/null 2>&1 ||
  fail "production Nginx image is unavailable: $image"

"$docker_bin" run --rm \
  --network none \
  --cap-drop ALL \
  --read-only \
  --tmpfs /etc/nginx/conf.d:size=1m,mode=0755 \
  --entrypoint /bin/sh \
  --env NGINX_ENVSUBST_FILTER='^REGISTRY_' \
  --env REGISTRY_PUBLIC_HOSTNAME=registry.test \
  --env REGISTRY_HTTPS_PORT=443 \
  --env REGISTRY_NGINX_MAX_BODY_SIZE=64k \
  --env REGISTRY_NGINX_REQUEST_RATE=10r/s \
  --env REGISTRY_NGINX_REQUEST_BURST=20 \
  --env REGISTRY_NGINX_CONNECTION_LIMIT=20 \
  "$image" \
  -ec '
    test "$(stat -c "%a %u:%g" /etc/nginx/templates)" = "755 0:0"
    test "$(stat -c "%a %u:%g" /etc/nginx/templates/registry.conf.template)" = "444 0:0"
    find /etc/nginx/templates -follow -type f -maxdepth 1 -print \
      | grep -Fxq /etc/nginx/templates/registry.conf.template
    /docker-entrypoint.d/20-envsubst-on-templates.sh
    test -s /etc/nginx/conf.d/registry.conf
    ! grep -Fq "\${REGISTRY_" /etc/nginx/conf.d/registry.conf
  ' >/dev/null ||
  fail "capability-reduced template discovery or rendering failed"

printf 'Production Nginx image contract: PASS\n'
