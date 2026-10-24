#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:-$PWD}"
RESET_SCRIPT="${REPO_ROOT}/build/scripts/reset-demo-state.sh"
TEST_ROOT="$(mktemp -d /tmp/myscoutee-demo-reset-test.XXXXXX)"

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "${TEST_ROOT}/bin"
cat > "${TEST_ROOT}/bin/docker" <<'EOF'
#!/usr/bin/env sh
if [ "${1:-}" = inspect ]; then
  printf '%s\n' healthy
  exit 0
fi
if [ "${1:-}" = exec ]; then
  count=$(cat "${DEMO_RESET_READY_COUNT:?}" 2>/dev/null || printf 0)
  count=$((count + 1))
  printf '%s\n' "$count" > "$DEMO_RESET_READY_COUNT"
  [ "${DEMO_RESET_NEVER_READY:-false}" != true ] && [ "$count" -ge 2 ]
  exit $?
fi
exit 64
EOF
chmod 0755 "${TEST_ROOT}/bin/docker"

cat > "${TEST_ROOT}/compose" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "${DEMO_RESET_COMMAND_LOG:?}"
if [ "${DEMO_RESET_FAIL_INITIALIZER:-false}" = true ]; then
  case "$*" in *admin\ /docker-entrypoint-initdb.d/db_init.js*) exit 91;; esac
fi
if [ "${1:-}" = exec ] && [ "$(cat "${DEMO_RESET_READY_COUNT:?}")" -lt 2 ]; then
  echo "Reset started while MongoDB was still initializing" >&2
  exit 90
fi
exit 0
EOF
chmod 0755 "${TEST_ROOT}/compose"

cat > "${TEST_ROOT}/myscoutee.env" <<'EOF'
MONGO_DEMO_DATABASE=demo_db
MONGO_REAL_DATABASE=production_db
EOF
printf '%s\n' 1.0.0 > "${TEST_ROOT}/marker"

PATH="${TEST_ROOT}/bin:${PATH}" \
DEMO_RESET_COMMAND_LOG="${TEST_ROOT}/commands.log" \
DEMO_RESET_READY_COUNT="${TEST_ROOT}/ready-count" \
MYSCOUTEE_COMPOSE_SCRIPT="${TEST_ROOT}/compose" \
MYSCOUTEE_ENV_FILE="${TEST_ROOT}/myscoutee.env" \
MYSCOUTEE_DEMO_RESET_MARKER="${TEST_ROOT}/marker" \
MYSCOUTEE_DEMO_RESET_WAIT_SECONDS=3 \
MYSCOUTEE_DEMO_RESET_ALLOW_NON_ROOT_FOR_TESTS=true \
  bash "${RESET_SCRIPT}" >/dev/null

[[ ! -e "${TEST_ROOT}/marker" ]] \
  || fail "successful reset did not consume the install marker"
[[ "$(cat "${TEST_ROOT}/ready-count")" -ge 2 ]] \
  || fail "reset did not wait for the final MongoDB process"
grep -Fxq 'up -d mongodb minio' "${TEST_ROOT}/commands.log" \
  || fail "reset did not start only the MongoDB and MinIO prerequisites"
grep -Fq 'MONGO_RESET_DATABASE=demo_db' "${TEST_ROOT}/commands.log" \
  || fail "reset did not pin its destructive Mongo operation to demo_db"
grep -Fq 'dropUser(process.env.MONGO_APP_USERNAME)' "${TEST_ROOT}/commands.log" \
  || fail "reset did not remove a stale demo-scoped application user"
grep -Fq 'MONGO_IMPORT_ALL_SEED_DATABASES=false' "${TEST_ROOT}/commands.log" \
  || fail "reset could import another database"
grep -Fq 'MONGO_SEED_DIRECTORY=demo_db' "${TEST_ROOT}/commands.log" \
  || fail "reset did not select the packaged demo seed"
grep -Fq 'admin /docker-entrypoint-initdb.d/db_init.js' "${TEST_ROOT}/commands.log" \
  || fail "reset did not replay the complete canonical initializer"
grep -Fq 'MONGO_REAL_DATABASE=production_db' "${TEST_ROOT}/commands.log" \
  || fail "initializer lost the production database boundary"
grep -Fq 'Incomplete Explore seed collection:' "${TEST_ROOT}/commands.log" \
  || fail "reset did not check every selected seed collection"
if grep -Fq 'db.events.countDocuments' "${TEST_ROOT}/commands.log"; then
  fail "shared reset requires a native-only domain"
fi
grep -Fq 'images/demo-assets images/demo-events images/demo-profiles' \
  "${TEST_ROOT}/commands.log" \
  || fail "reset did not restrict MinIO cleanup to package-owned demo prefixes"

printf '%s\n' 1.0.0 > "${TEST_ROOT}/marker"
if PATH="${TEST_ROOT}/bin:${PATH}" \
    DEMO_RESET_COMMAND_LOG="${TEST_ROOT}/initializer-failure.log" \
    DEMO_RESET_READY_COUNT="${TEST_ROOT}/ready-count" \
    DEMO_RESET_FAIL_INITIALIZER=true \
    MYSCOUTEE_COMPOSE_SCRIPT="${TEST_ROOT}/compose" \
    MYSCOUTEE_ENV_FILE="${TEST_ROOT}/myscoutee.env" \
    MYSCOUTEE_DEMO_RESET_MARKER="${TEST_ROOT}/marker" \
    MYSCOUTEE_DEMO_RESET_WAIT_SECONDS=3 \
    MYSCOUTEE_DEMO_RESET_ALLOW_NON_ROOT_FOR_TESTS=true \
      bash "${RESET_SCRIPT}" >/dev/null 2>&1; then
  fail "reset accepted a failed index initialization"
fi
[[ -f "${TEST_ROOT}/marker" ]] || fail "failed initialization consumed the retry marker"
if grep -Fq 'const userCount' "${TEST_ROOT}/initializer-failure.log"; then
  fail "reset continued after index initialization failed"
fi

printf '%s\n' 1.0.0 > "${TEST_ROOT}/marker"
if PATH="${TEST_ROOT}/bin:${PATH}" \
    DEMO_RESET_COMMAND_LOG="${TEST_ROOT}/timeout.log" \
    DEMO_RESET_READY_COUNT="${TEST_ROOT}/timeout-count" \
    DEMO_RESET_NEVER_READY=true \
    MYSCOUTEE_COMPOSE_SCRIPT="${TEST_ROOT}/compose" \
    MYSCOUTEE_ENV_FILE="${TEST_ROOT}/myscoutee.env" \
    MYSCOUTEE_DEMO_RESET_MARKER="${TEST_ROOT}/marker" \
    MYSCOUTEE_DEMO_RESET_WAIT_SECONDS=1 \
    MYSCOUTEE_DEMO_RESET_ALLOW_NON_ROOT_FOR_TESTS=true \
      bash "${RESET_SCRIPT}" >/dev/null 2>&1; then
  fail "reset accepted an unfinished MongoDB initialization"
fi
[[ -f "${TEST_ROOT}/marker" ]] || fail "timeout consumed the retry marker"
[[ "$(cat "${TEST_ROOT}/timeout.log")" == 'up -d mongodb minio' ]] \
  || fail "initialization timeout mutated seed data"

cat > "${TEST_ROOT}/myscoutee.env" <<'EOF'
MONGO_DEMO_DATABASE=production_db
MONGO_REAL_DATABASE=production_db
EOF
printf '%s\n' 1.0.0 > "${TEST_ROOT}/marker"
if PATH="${TEST_ROOT}/bin:${PATH}" \
    DEMO_RESET_COMMAND_LOG="${TEST_ROOT}/rejected.log" \
    MYSCOUTEE_COMPOSE_SCRIPT="${TEST_ROOT}/compose" \
    MYSCOUTEE_ENV_FILE="${TEST_ROOT}/myscoutee.env" \
    MYSCOUTEE_DEMO_RESET_MARKER="${TEST_ROOT}/marker" \
    MYSCOUTEE_DEMO_RESET_ALLOW_NON_ROOT_FOR_TESTS=true \
      bash "${RESET_SCRIPT}" >/dev/null 2>&1; then
  fail "reset accepted a production database as its target"
fi
[[ -f "${TEST_ROOT}/marker" ]] \
  || fail "a rejected reset consumed its retry marker"
[[ ! -e "${TEST_ROOT}/rejected.log" ]] \
  || fail "a rejected reset invoked Compose"

echo "Demo reset boundary test passed."
