#!/usr/bin/env bash
set -euo pipefail
ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
cp "$ROOT/build/scripts/"{restart-update-stack.sh,release-project.sh} "$TEST_DIR/"
install -m 0644 "$ROOT/config/packaging/release-project.json" "$TEST_DIR/"
mkdir "$TEST_DIR/bin"
export UPDATE_RESTART_TRACE="$TEST_DIR/trace"
export UPDATE_TEST_DOCKER="$(command -v docker)"
export UPDATE_TEST_MODEL="$ROOT/config/packaging/compose/docker-compose.production.yml"
export UPDATE_TEST_ENV_FILE="$TEST_DIR/installed.env"
export UPDATE_TEST_OLD_VERSION=1.3.0-qa.1
export UPDATE_TEST_TARGET_VERSION=1.3.0-qa.2
cat > "$UPDATE_TEST_ENV_FILE" <<'ENV'
MYSCOUTEE_VERSION=1.3.0-qa.2
NGINX_PRODUCTION_IMAGE=myscoutee-nginx:1.3.0-qa.2-prod
MYSCOUTEE_PRODUCTION_IMAGE=myscoutee-api:1.3.0-qa.2-prod
MINIO_PRODUCTION_IMAGE=myscoutee-minio:1.3.0-qa.2-prod
REGISTRY_DEMO_IMAGE=myscoutee-registry:1.3.0-qa.2-prod
PAYMENT_SIMULATOR_IMAGE=myscoutee-payment-simulator:1.3.0-qa.2-prod
MCP_IMAGE=myscoutee-mcp:1.3.0-qa.2-prod
MONGO_IMPORT_ALLOWED_COLLECTIONS_BY_DB=fixture
ENV
# Simulate the long-running worker's pre-install environment.
export MYSCOUTEE_VERSION=1.3.0-qa.1
export NGINX_PRODUCTION_IMAGE=myscoutee-nginx:1.3.0-qa.1-prod
export MYSCOUTEE_PRODUCTION_IMAGE=myscoutee-api:1.3.0-qa.1-prod
export MINIO_PRODUCTION_IMAGE=myscoutee-minio:1.3.0-qa.1-prod
export REGISTRY_DEMO_IMAGE=myscoutee-registry:1.3.0-qa.1-prod
export PAYMENT_SIMULATOR_IMAGE=myscoutee-payment-simulator:1.3.0-qa.1-prod
export MCP_IMAGE=myscoutee-mcp:1.3.0-qa.1-prod
export PATH="$TEST_DIR/bin:$PATH"
export MYSCOUTEE_COMPOSE_SCRIPT="$TEST_DIR/compose"
for command in compose reset-demo-state.sh sync-i18n-seeds.sh migrate-production-data.sh; do
  cat > "$TEST_DIR/$command" <<'SH'
#!/bin/sh
set -eu
if [ "$(basename "$0")" = compose ]; then
  if [ "${1:-}" = config ]; then
    exec "$UPDATE_TEST_DOCKER" compose -f "$UPDATE_TEST_MODEL" --env-file "$UPDATE_TEST_ENV_FILE" "$@"
  fi
  images="$("$UPDATE_TEST_DOCKER" compose -f "$UPDATE_TEST_MODEL" --env-file "$UPDATE_TEST_ENV_FILE" config --no-env-resolution --images)"
  if printf '%s\n' "$images" | grep -Fq "$UPDATE_TEST_OLD_VERSION-prod"; then
    echo 'FAIL: stale worker image overrides the newly installed configuration' >&2
    exit 1
  fi
  printf '%s\n' "$images" | grep -Fq "myscoutee-api:$UPDATE_TEST_TARGET_VERSION-prod"
fi
printf '%s %s\n' "$(basename "$0")" "$*" >> "$UPDATE_RESTART_TRACE"
SH
  chmod +x "$TEST_DIR/$command"
done
cat > "$TEST_DIR/bin/systemctl" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$TEST_DIR/bin/docker" <<'SH'
#!/bin/sh
printf '%s\n' "${UPDATE_TEST_HEALTH:-healthy}"
SH
chmod +x "$TEST_DIR/bin/"*
bash "$TEST_DIR/restart-update-stack.sh" > "$TEST_DIR/phases"
python3 - "$UPDATE_RESTART_TRACE" <<'PY'
import sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text().splitlines()
assert lines == [
    'compose stop profilemanagement',
    'reset-demo-state.sh ',
    'sync-i18n-seeds.sh --prepare-only',
    'migrate-production-data.sh ',
    'compose up -d --no-deps --wait --wait-timeout 300 mcp minio mongodb payment-simulator redis registry stun',
    'compose up -d --no-deps profilemanagement',
    'compose up -d --no-deps nginx',
], lines
PY
: > "$UPDATE_RESTART_TRACE"
if UPDATE_TEST_HEALTH=unhealthy bash "$TEST_DIR/restart-update-stack.sh"; then
  echo 'FAIL: unhealthy backend was accepted' >&2
  exit 1
fi
if grep -q 'nginx\| down\|stop nginx' "$UPDATE_RESTART_TRACE"; then
  echo 'FAIL: ingress touched after backend health failure' >&2
  exit 1
fi
# Validate all invoked service names against the real Compose model, not a copied expectation.
# The fake docker owns health probes only; use the host Compose parser for this check.
MONGO_IMPORT_ALLOWED_COLLECTIONS_BY_DB=fixture PATH="${PATH#*:}" docker compose -f "$ROOT/config/packaging/compose/docker-compose.production.yml" config --no-env-resolution --services > "$TEST_DIR/services"
python3 - "$UPDATE_RESTART_TRACE" "$TEST_DIR/services" <<'PYTEST'
import sys
from pathlib import Path
services = set(Path(sys.argv[2]).read_text().splitlines())
for line in Path(sys.argv[1]).read_text().splitlines():
    if line.startswith('compose up '):
        parts = line.split()
        start = parts.index('300') + 1 if '300' in parts else parts.index('--no-deps') + 1
        assert set(parts[start:]) <= services, (parts[start:], services)
PYTEST
sed -i 's/1.3.0-qa.2/1.3.0-qa.1/g' "$UPDATE_TEST_ENV_FILE"
export UPDATE_TEST_OLD_VERSION=1.3.0-qa.2
export UPDATE_TEST_TARGET_VERSION=1.3.0-qa.1
for key in MYSCOUTEE_VERSION NGINX_PRODUCTION_IMAGE MYSCOUTEE_PRODUCTION_IMAGE \
  MINIO_PRODUCTION_IMAGE REGISTRY_DEMO_IMAGE PAYMENT_SIMULATOR_IMAGE MCP_IMAGE; do
  export "$key=${!key/1.3.0-qa.1/1.3.0-qa.2}"
done
bash "$TEST_DIR/restart-update-stack.sh" > "$TEST_DIR/rollback-phases"
echo 'PASS: ingress retained until backend health; failure retains existing ingress.'
echo 'PASS: upgrade and rollback use installed image selection, not the worker environment.'
