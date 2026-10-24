#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:-$PWD}"
SYNC_SCRIPT="${REPO_ROOT}/build/scripts/sync-i18n-seeds.sh"
TEST_ROOT="$(mktemp -d /tmp/myscoutee-i18n-runtime-seed-sync-test.XXXXXX)"
FAKE_BIN="${TEST_ROOT}/bin"
SEED_DIR="${TEST_ROOT}/seeds"
COMMAND_LOG="${TEST_ROOT}/commands.log"

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  echo "i18n runtime seed sync test failed: $*" >&2
  exit 1
}

mkdir -p "${FAKE_BIN}" "${SEED_DIR}"
printf '[]\n' > "${SEED_DIR}/i18n_bundles.json"
printf '[]\n' > "${SEED_DIR}/i18n_messages.json"

cat > "${FAKE_BIN}/docker" <<'SCRIPT'
#!/usr/bin/env bash
printf 'docker\t%s\n' "$*" >> "${I18N_SYNC_TEST_LOG:?}"
if [[ "${1:-}" == "inspect" ]]; then
  printf '%s\n' "${I18N_SYNC_TEST_MONGO_STATUS:-healthy}"
fi
SCRIPT

cat > "${TEST_ROOT}/compose.sh" <<'SCRIPT'
#!/usr/bin/env bash
printf 'compose\t%s\n' "$*" >> "${I18N_SYNC_TEST_LOG:?}"
if [[ "${I18N_SYNC_TEST_FAIL_MESSAGES:-false}" == true \
  && "$*" == *"i18n_messages.json"* ]]; then
  exit 19
fi
SCRIPT

chmod 0755 "${FAKE_BIN}/docker" "${TEST_ROOT}/compose.sh"

run_sync() {
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  I18N_SYNC_TEST_LOG="${COMMAND_LOG}" \
  MYSCOUTEE_COMPOSE_SCRIPT="${TEST_ROOT}/compose.sh" \
  MYSCOUTEE_I18N_SEED_DIR_HOST="${SEED_DIR}" \
  MYSCOUTEE_I18N_SEED_DIR_CONTAINER=/packaged-production-seed \
  MYSCOUTEE_MONGO_CONTAINER=production-mongodb \
  MYSCOUTEE_I18N_SYNC_WAIT_SECONDS=1 \
    "${SYNC_SCRIPT}"
}

run_sync >/dev/null

grep -Fxq $'compose\tup -d mongodb' "${COMMAND_LOG}" \
  || fail "MongoDB was not started before synchronization"
grep -Fxq \
  $'docker\tinspect production-mongodb --format {{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
  "${COMMAND_LOG}" \
  || fail "MongoDB health was not checked"
for seed_name in i18n_messages i18n_bundles; do
  grep -Fxq \
    $'compose\texec -T -e MONGO_IMPORT_SINGLE_FILE=/packaged-production-seed/'"${seed_name}"$'.json mongodb /docker-entrypoint-initdb.d/mongo_import.sh' \
    "${COMMAND_LOG}" \
    || fail "${seed_name} was not upserted from the packaged seed"
done
messages_line="$(grep -n 'MONGO_IMPORT_SINGLE_FILE=.*/i18n_messages.json' "${COMMAND_LOG}" | cut -d: -f1)"
bundles_line="$(grep -n 'MONGO_IMPORT_SINGLE_FILE=.*/i18n_bundles.json' "${COMMAND_LOG}" | cut -d: -f1)"
[[ "${messages_line}" -lt "${bundles_line}" ]] \
  || fail "bundle metadata was published before its messages"

: > "${COMMAND_LOG}"
if I18N_SYNC_TEST_FAIL_MESSAGES=true run_sync >/dev/null 2>&1; then
  fail "a failed message import did not fail synchronization"
fi
if grep -Eq 'MONGO_IMPORT_SINGLE_FILE=.*/i18n_bundles\.json' "${COMMAND_LOG}"; then
  fail "bundle metadata was published after a failed message import"
fi

rm -f "${SEED_DIR}/i18n_messages.json"
if run_sync >/dev/null 2>&1; then
  fail "a missing managed seed did not fail closed"
fi

printf '[]\n' > "${SEED_DIR}/i18n_messages.json"
if I18N_SYNC_TEST_MONGO_STATUS=unhealthy run_sync >/dev/null 2>&1; then
  fail "an unhealthy MongoDB container did not fail closed"
fi

echo "i18n runtime seed sync tests passed."
