#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/release-project.sh"
release_project_load "${SCRIPT_DIR}" "$(stat -c %u "${BASH_SOURCE[0]}")" || {
  echo 'The package-owned release project policy is missing or unsafe.' >&2; exit 1;
}

default_server_dir() {
  if [[ "${SCRIPT_DIR}" == ${RELEASE_PROJECT_ROOT}/packaging/scripts \
    && -f ${RELEASE_PROJECT_ROOT}/server/docker-compose-prod.yml ]]; then
    printf '%s/server' "${RELEASE_PROJECT_ROOT}"
    return
  fi

  local repo_root
  repo_root="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
  printf '%s/server' "${repo_root}"
}

SERVER_DIR="${MYSCOUTEE_SERVER_DIR:-$(default_server_dir)}"
COMPOSE_SCRIPT="${MYSCOUTEE_COMPOSE_SCRIPT:-${SCRIPT_DIR}/myscoutee-compose.sh}"
ENV_FILE="${MYSCOUTEE_ENV_FILE:-/etc/${RELEASE_PROJECT_NAME}/${RELEASE_PROJECT_NAME}.env}"
RESET_MARKER="${MYSCOUTEE_DEMO_RESET_MARKER:-/var/lib/${RELEASE_PROJECT_NAME}/demo-reset-required}"
WAIT_SECONDS="${MYSCOUTEE_DEMO_RESET_WAIT_SECONDS:-180}"
MONGO_CONTAINER="${MYSCOUTEE_MONGO_CONTAINER:-mongodb}"
MINIO_CONTAINER="${MYSCOUTEE_MINIO_CONTAINER:-minio}"

fail() {
  echo "MyScoutee demo reset failed: $*" >&2
  exit 1
}

is_truthy() {
  case "${1,,}" in
    1|true|yes|on|enabled)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

read_env_file_value() {
  local key="$1"
  local file="$2"
  local line value

  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  line="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "${file}" | tail -n 1)"
  [[ -n "${line}" ]] || return 1
  value="${line%$'\r'}"
  if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "${value}"
}

wait_for_container_health() {
  local container="$1"
  local status=""

  for ((attempt = 1; attempt <= WAIT_SECONDS; attempt++)); do
    status="$(
      docker inspect "${container}" \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        2>/dev/null \
        || true
    )"
    case "${status}" in
      healthy)
        # The official Mongo image starts a temporary daemon while its entrypoint
        # imports the initial datasets. That daemon already answers health probes.
        # Resetting demo_db then invalidates the importer's credentials and leaves
        # production seeds incomplete. Only the final mongod replaces PID 1.
        if [[ "${container}" == "${MONGO_CONTAINER}" ]] \
          && ! docker exec "${container}" sh -c \
            'test "$(cat /proc/1/comm)" = mongod' >/dev/null 2>&1; then
          sleep 1
          continue
        fi
        return 0
        ;;
      unhealthy|exited|dead)
        fail "${container} entered ${status} state before the reset"
        ;;
    esac
    sleep 1
  done

  fail "${container} did not become healthy within ${WAIT_SECONDS} seconds"
}

[[ -e "${RESET_MARKER}" || -L "${RESET_MARKER}" ]] || exit 0
[[ -f "${RESET_MARKER}" && ! -L "${RESET_MARKER}" ]] \
  || fail "reset marker must be a regular file: ${RESET_MARKER}"
if (( EUID != 0 )) \
  && ! is_truthy "${MYSCOUTEE_DEMO_RESET_ALLOW_NON_ROOT_FOR_TESTS:-false}"; then
  fail "the demo reset must run as root"
fi
[[ "${WAIT_SECONDS}" =~ ^[1-9][0-9]*$ && "${WAIT_SECONDS}" -le 600 ]] \
  || fail "MYSCOUTEE_DEMO_RESET_WAIT_SECONDS must be between 1 and 600"
[[ -x "${COMPOSE_SCRIPT}" && ! -L "${COMPOSE_SCRIPT}" ]] \
  || fail "compose helper is missing, not executable, or a symbolic link: ${COMPOSE_SCRIPT}"

demo_database="$(read_env_file_value MONGO_DEMO_DATABASE "${ENV_FILE}" || true)"
real_database="$(read_env_file_value MONGO_REAL_DATABASE "${ENV_FILE}" || true)"
demo_database="${demo_database:-demo_db}"
real_database="${real_database:-production_db}"

# This destructive path intentionally accepts only the packaged Explore
# database. A typo or an operator override must never turn it into a generic
# database-drop helper.
[[ "${demo_database}" == "demo_db" ]] \
  || fail "MONGO_DEMO_DATABASE must be exactly demo_db for an automatic reset"
[[ "${real_database}" != "${demo_database}" ]] \
  || fail "the demo and production database names must be different"

echo "Rebuilding disposable Explore state from the installed package."
"${COMPOSE_SCRIPT}" up -d mongodb minio
wait_for_container_health "${MONGO_CONTAINER}"
wait_for_container_health "${MINIO_CONTAINER}"

# Delete only package-owned Explore prefixes. Operator/user uploads and system
# media remain untouched. The seed bootstrap then recreates the exact current
# package contents and removes the possibility of orphaned legacy demo media.
"${COMPOSE_SCRIPT}" exec -T minio sh -eu -c '
alias_name=myscoutee-demo-reset
endpoint="${MINIO_ENDPOINT:-http://127.0.0.1:9000}"
bucket="${MEDIA_BUCKET:-myscoutee-media}"
mc alias set "$alias_name" "$endpoint" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
for prefix in images/demo-assets images/demo-events images/demo-profiles; do
  mc rm --recursive --force "$alias_name/$bucket/$prefix/" >/dev/null 2>&1 || true
done
/bin/sh /scripts/bootstrap_minio_seed.sh >/dev/null
'

# Authenticate as the Mongo root user only for the narrowly guarded database
# drop and recreation of the demo-scoped application user. Production data is
# neither imported nor mutated by this path.
"${COMPOSE_SCRIPT}" exec -T \
  -e "MONGO_RESET_DATABASE=${demo_database}" \
  mongodb sh -eu -c '
mongosh --quiet \
  --username "$MONGO_INITDB_ROOT_USERNAME" \
  --password "$MONGO_INITDB_ROOT_PASSWORD" \
  --authenticationDatabase admin \
  admin \
  --eval '\''
const demoName = process.env.MONGO_RESET_DATABASE;
if (demoName !== "demo_db") {
  throw new Error("automatic reset target rejected: " + demoName);
}
const result = db.getSiblingDB(demoName).dropDatabase();
if (result.ok !== 1) {
  throw new Error("failed to drop " + demoName);
}
const demoDb = db.getSiblingDB(demoName);
// MongoDB can retain database-scoped users across dropDatabase(). Remove only
// the packaged demo application identity before recreating it. The production
// database and its users are never selected by this guarded script.
if (demoDb.getUser(process.env.MONGO_APP_USERNAME) !== null) {
  if (!demoDb.dropUser(process.env.MONGO_APP_USERNAME)) {
    throw new Error("failed to remove the stale demo application user");
  }
}
demoDb.createUser({
  user: process.env.MONGO_APP_USERNAME,
  pwd: process.env.MONGO_APP_PASSWORD,
  roles: [{ role: "readWrite", db: demoName }]
});
'\'' >/dev/null
'

"${COMPOSE_SCRIPT}" exec -T \
  -e "MONGO_APP_DATABASE=${demo_database}" \
  -e "MONGO_SEED_DIRECTORY=${demo_database}" \
  -e "MONGO_IMPORT_ALL_SEED_DATABASES=false" \
  -e "MONGO_IMPORT_REPLACE_COLLECTIONS=true" \
  mongodb /docker-entrypoint-initdb.d/mongo_import.sh >/dev/null

# Import can recreate collections. Replay the canonical initializer afterwards,
# scoped to Explore, so reset has every fresh-install index rather than only the
# importer's collection-specific subset. A failed index build keeps the marker.
"${COMPOSE_SCRIPT}" exec -T \
  -e "MONGO_RESET_DATABASE=${demo_database}" \
  -e "MONGO_REAL_DATABASE=${real_database}" \
  mongodb sh -eu -c '
mongosh --quiet \
  --username "$MONGO_INITDB_ROOT_USERNAME" \
  --password "$MONGO_INITDB_ROOT_PASSWORD" \
  --authenticationDatabase admin \
  admin /docker-entrypoint-initdb.d/db_init.js >/dev/null
'

"${COMPOSE_SCRIPT}" exec -T \
  -e "MONGO_RESET_DATABASE=${demo_database}" \
  mongodb sh -eu -c '
mongosh --quiet \
  --username "$MONGO_APP_USERNAME" \
  --password "$MONGO_APP_PASSWORD" \
  --authenticationDatabase "$MONGO_RESET_DATABASE" \
  "$MONGO_RESET_DATABASE" \
  --eval '\''
const userCount = db.users.countDocuments({});
// Check every packaged collection, including empty baselines. The package
// selects the product data; this shared reset must not require native events
// in a project that intentionally has only sample cards and chat.
const fs = require("fs");
const directory = "/docker-entrypoint-initdb.d/demo_db";
const files = fs.readdirSync(directory).filter(name => name.endsWith(".json")).sort();
if (files.length === 0) throw new Error("No packaged Explore seed files");
const expectedByCollection = {};
for (const file of files) {
  const name = file.slice(0, -5);
  const collection = name === "adminUsers" ? "users" : name;
  const rows = EJSON.parse(fs.readFileSync(directory + "/" + file, "utf8"));
  if (!Array.isArray(rows) || rows.some(row => row._id == null)) {
    throw new Error("Invalid Explore seed file: " + file);
  }
  if (!expectedByCollection[collection]) expectedByCollection[collection] = new Map();
  for (const row of rows) expectedByCollection[collection].set(EJSON.stringify(row._id), row._id);
}
for (const [name, identifiers] of Object.entries(expectedByCollection)) {
  const collection = db.getCollection(name);
  const expected = identifiers.size;
  if (collection.countDocuments({}) !== expected
      || (expected > 0 && collection.countDocuments({_id: {$in: [...identifiers.values()]}}) !== expected)) {
    throw new Error("Incomplete Explore seed collection: " + name);
  }
}
const externalImageCount = db.users.countDocuments({
  images: { $elemMatch: { $regex: /^https?:\/\//i } }
});
if (userCount < 1 || externalImageCount !== 0) {
  throw new Error(
    "invalid Explore seed: users=" + userCount
      + ", externalImages=" + externalImageCount
  );
}
'\'' >/dev/null
'

rm -f -- "${RESET_MARKER}"
echo "Explore demo_db and package-owned demo media were rebuilt; production state was preserved."
