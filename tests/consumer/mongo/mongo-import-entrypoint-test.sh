#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:-$PWD}"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

# No database commands are needed: source the real hook with an absent single
# seed file, just as Mongo's entrypoint sources it, and prove its caller lives.
MONGO_IMPORT_SINGLE_FILE="${TEST_ROOT}/absent.json" \
MONGO_APP_DATABASE=entrypoint_contract_test \
  bash -c '. "$1"; printf "entrypoint-continued\n"' _ \
    "${REPO_ROOT}/server/docker/conf/mongodb/mongo_import.sh" > "${TEST_ROOT}/result"
grep -Fxq entrypoint-continued "${TEST_ROOT}/result"

# Every deployment must carry the project policy beside the shared engine.
# Missing packaging input must fail before any database command can run.
cp "${REPO_ROOT}/server/docker/conf/mongodb/mongo_import.sh" "${TEST_ROOT}/mongo_import.sh"
if MONGO_IMPORT_SINGLE_FILE="${TEST_ROOT}/absent.json" \
    bash "${TEST_ROOT}/mongo_import.sh" > "${TEST_ROOT}/missing-policy" 2>&1; then
  echo "Importer accepted a missing project policy." >&2
  exit 1
fi
grep -Fq 'mongo-seed-policy.inc' "${TEST_ROOT}/missing-policy"
cp "${REPO_ROOT}/server/docker/conf/mongodb/mongo-seed-policy.inc" "${TEST_ROOT}/"
MONGO_IMPORT_SINGLE_FILE="${TEST_ROOT}/absent.json" \
  bash -c 'cd /; . "$1"; printf "entrypoint-continued\n"' _ \
    "${TEST_ROOT}/mongo_import.sh" > "${TEST_ROOT}/relocated"
grep -Fxq entrypoint-continued "${TEST_ROOT}/relocated"

# Exercise the multi-database dispatch without touching real seed directories.
# The functions are replaced only in this test copy; dispatch remains verbatim.
python3 - "${REPO_ROOT}/server/docker/conf/mongodb/mongo_import.sh" "${TEST_ROOT}/dispatch.sh" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
dispatch=source[source.rindex('if [ -n "${single_file}" ]; then'):]
Path(sys.argv[2]).write_text('''set -eu
single_file=""
db_name=production_db
seed_dir_name=myscoutee_db
import_seed_directory() { printf 'import %s %s\\n' "$1" "$2"; }
''' + dispatch)
PY
MONGO_IMPORT_ALL_SEED_DATABASES=true bash -c '. "$1"; echo entrypoint-continued' _ \
  "${TEST_ROOT}/dispatch.sh" > "${TEST_ROOT}/multi"
printf 'import demo_db demo_db\nimport production_db myscoutee_db\nentrypoint-continued\n' \
  | cmp - "${TEST_ROOT}/multi"
echo "Mongo import entrypoint continuation passed."
