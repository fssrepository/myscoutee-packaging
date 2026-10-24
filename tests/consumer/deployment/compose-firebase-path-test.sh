#!/usr/bin/env bash
set -euo pipefail
ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:-$PWD}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/server" "$WORK/bin" "$WORK/operator-managed"
printf '%s\n' FIREBASE_ENABLED=true MONGO_REPLICA_SET_ENABLED=false > "$WORK/server/.env"
export FIREBASE_TEST_TRACE="$WORK/trace"
export FIREBASE_TEST_FILE="$WORK/operator-managed/firebase.json"
export MYSCOUTEE_SERVER_DIR="$WORK/server"
export MYSCOUTEE_ENV_FILE="$WORK/server/.env"
cat > "$WORK/bin/docker" <<'MOCK'
#!/bin/bash
set -eu
if [[ " $* " == *' config '* ]]; then
  jq -n --arg file "$FIREBASE_TEST_FILE" '{secrets:{"firebase-service-account":{file:$file}}}'
else
  printf '%s\n' "$*" >> "$FIREBASE_TEST_TRACE"
fi
MOCK
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"
if bash "$ROOT/build/scripts/myscoutee-compose.sh" up -d > "$WORK/output" 2>&1; then
  echo 'FAIL: accepted a missing operator Firebase file.' >&2; exit 1
fi
[[ ! -f "$FIREBASE_TEST_TRACE" ]]
printf '{"fixture":true}\n' > "$FIREBASE_TEST_FILE"
bash "$ROOT/build/scripts/myscoutee-compose.sh" up -d
[[ "$(cat "$FIREBASE_TEST_TRACE")" == 'compose -f docker-compose-prod.yml up -d' ]]
echo 'PASS: Firebase readiness uses the selected Compose secret path and fails before startup when absent.'
