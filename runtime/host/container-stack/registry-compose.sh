#!/usr/bin/env bash
set -Eeuo pipefail

install_root="${MYSCOUTEE_REGISTRY_INSTALL_ROOT:-/opt/@@PACKAGE_NAME@@}"
env_file="${MYSCOUTEE_REGISTRY_ENV_FILE:-/etc/@@PACKAGE_NAME@@/registry.env}"
compose_file="$install_root/compose.yaml"
docker_bin="${DOCKER_BIN:-docker}"

[[ -f "$compose_file" && ! -L "$compose_file" ]] || {
  printf 'registry-compose: missing installed compose model: %s\n' \
    "$compose_file" >&2
  exit 1
}
[[ -f "$env_file" && ! -L "$env_file" ]] || {
  printf 'registry-compose: missing protected environment: %s\n' \
    "$env_file" >&2
  exit 1
}

exec "$docker_bin" compose \
  --project-name @@PACKAGE_NAME@@ \
  --env-file "$env_file" \
  --file "$compose_file" \
  "$@"
