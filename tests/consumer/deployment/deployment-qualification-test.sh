#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}"
QUALIFIER="${REPO_ROOT}/build/scripts/qualify-deployment.sh"
DIAGNOSTICS="${REPO_ROOT}/build/scripts/deployment-diagnostics.sh"
MONGO_SMOKE="${REPO_ROOT}/build/scripts/smoke-mongo-compatibility.sh"
TEST_ROOT="$(mktemp -d /tmp/myscoutee-deployment-qualification-test.XXXXXX)"
FAKE_BIN="${TEST_ROOT}/bin"
COMMAND_LOG="${TEST_ROOT}/commands.log"
export QUALIFICATION_COMPOSE_CONFIG="${TEST_ROOT}/compose.json"
MONGO_IMPORT_ALLOWED_COLLECTIONS_BY_DB=fixture docker compose -f "${REPO_ROOT}/config/packaging/compose/docker-compose.production.yml" config --no-env-resolution --format json > "$QUALIFICATION_COMPOSE_CONFIG"

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  echo "Deployment qualification test failed: $1" >&2
  exit 1
}

check_mongo_reference() {
  MYSCOUTEE_SMOKE_LIBRARY_ONLY=true bash -c '
    source "$1"
    docker() { printf "%s" "$TEST_UPSTREAM"; }
    check_configured_mongo_image "$2"
  ' _ "${MONGO_SMOKE}" "$1"
}
TEST_UPSTREAM='' check_mongo_reference mongo:8.0.4 >/dev/null \
  || fail 'official Mongo reference rejected'
TEST_UPSTREAM='mongo:8.0.4' check_mongo_reference 'ghcr.io/fssrepository/myscoutee-mongodb@sha256:0123' >/dev/null \
  || fail 'retained digest with supported upstream rejected'
if TEST_UPSTREAM='mongo:7.0.4' check_mongo_reference 'ghcr.io/fssrepository/myscoutee-mongodb@sha256:0123' >/dev/null 2>&1; then
  fail 'unsupported Mongo upstream accepted'
fi
if TEST_UPSTREAM='' check_mongo_reference 'ghcr.io/fssrepository/myscoutee-mongodb@sha256:0123' >/dev/null 2>&1; then
  fail 'unidentified Mongo upstream accepted'
fi

SMOKE_FALLBACK_OUTPUT="$(
  MYSCOUTEE_SMOKE_LIBRARY_ONLY=true \
    bash -c '
      source "$1"
      http_get() {
        printf "<html>permanent redirect</html>"
      }
      internal_get() {
        [[ "$1" == "/api/health" ]] || return 1
        printf "{\"status\":\"UP\"}"
      }
      check_http_or_internal \
        "redirect fallback health" "/api/health" "\"status\":\"UP\""
    ' _ "${MONGO_SMOKE}"
)"
grep -Fq 'ok    redirect fallback health' <<< "${SMOKE_FALLBACK_OUTPUT}" \
  || fail "a non-empty HTTP redirect did not fall back to the internal API"

INTERNAL_HEALTH_COMMAND="$(
  MYSCOUTEE_SMOKE_LIBRARY_ONLY=true \
    bash -c '
      source "$1"
      docker() {
        printf "%s\n" "$*"
      }
      internal_get "/api/health"
    ' _ "${MONGO_SMOKE}"
)"
[[ "${INTERNAL_HEALTH_COMMAND}" \
  == "exec myscoutee wget -qO- http://localhost:8080/health" ]] \
  || fail "internal smoke did not remove the public /api proxy prefix"

mkdir -p \
  "${FAKE_BIN}" \
  "${TEST_ROOT}/registry-state" \
  "${TEST_ROOT}/registry-keys"
: > "${COMMAND_LOG}"

cat > "${FAKE_BIN}/systemctl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'systemctl\t%s\n' "$*" >> "${QUALIFICATION_TEST_LOG:?}"
case "${1:-}" in
  is-active)
    [[ "${QUALIFICATION_TEST_SERVICE_ACTIVE:-true}" == true ]]
    ;;
esac
SCRIPT

cat > "${FAKE_BIN}/docker" <<'SCRIPT'
#!/usr/bin/env bash
printf 'docker\t%s\n' "$*" >> "${QUALIFICATION_TEST_LOG:?}"
case "${1:-}" in
  ps)
    if [[ "${QUALIFICATION_TEST_RESTARTING:-false}" == true ]]; then
      printf 'myscoutee Restarting (1) 1 second ago\n'
    fi
    ;;
  inspect)
    printf 'healthy\n'
    ;;
  exec)
    if [[ "${QUALIFICATION_TEST_I18N_VALID:-true}" == true ]]; then
      printf '{"lang":"hu","data":{"ok":"rendben"}}\n'
    else
      printf '{"lang":"en","data":{}}\n'
    fi
    ;;
esac
SCRIPT

cat > "${FAKE_BIN}/dpkg-query" <<'SCRIPT'
#!/usr/bin/env bash
printf 'dpkg-query\t%s\n' "$*" >> "${QUALIFICATION_TEST_LOG:?}"
printf '%s' "${QUALIFICATION_TEST_VERSION:-1.0.0}"
SCRIPT

cat > "${FAKE_BIN}/journalctl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'journalctl\t%s\n' "$*" >> "${QUALIFICATION_TEST_LOG:?}"
printf 'test journal\n'
SCRIPT

chmod 0755 \
  "${FAKE_BIN}/systemctl" \
  "${FAKE_BIN}/docker" \
  "${FAKE_BIN}/dpkg-query" \
  "${FAKE_BIN}/journalctl"

SMOKE_SCRIPT="${TEST_ROOT}/smoke.sh"
cat > "${SMOKE_SCRIPT}" <<'SCRIPT'
#!/usr/bin/env bash
printf 'smoke\tbase=%s start=%s timeout=%s\n' \
  "${MYSCOUTEE_BASE_URL:-}" \
  "${START_STACK:-}" \
  "${WAIT_TIMEOUT_SECONDS:-}" \
  >> "${QUALIFICATION_TEST_LOG:?}"
[[ "${QUALIFICATION_TEST_SMOKE_VALID:-true}" == true ]]
SCRIPT
chmod 0755 "${SMOKE_SCRIPT}"

COMPOSE_SCRIPT="${TEST_ROOT}/compose.sh"
cat > "${COMPOSE_SCRIPT}" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${1:-}" == config ]]; then cat "$QUALIFICATION_COMPOSE_CONFIG"; exit 0; fi
if [[ "$*" == "ps -a -q stun" ]]; then printf 'server-stun-1\n'; exit 0; fi
printf 'compose\t%s\n' "$*" >> "${QUALIFICATION_TEST_LOG:?}"
SCRIPT
chmod 0755 "${COMPOSE_SCRIPT}"

ENV_FILE="${TEST_ROOT}/myscoutee.env"
cat > "${ENV_FILE}" <<ENV
REGISTRY_BASE_URL=https://registry.example.test
REGISTRY_STATE_DIR_HOST=${TEST_ROOT}/registry-state
REGISTRY_KEY_DIR_HOST=${TEST_ROOT}/registry-keys
ENV

run_qualifier() {
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  QUALIFICATION_TEST_LOG="${COMMAND_LOG}" \
  MYSCOUTEE_QUALIFY_ALLOW_NON_ROOT_FOR_TESTS=true \
  MYSCOUTEE_ENV_FILE="${ENV_FILE}" \
  MYSCOUTEE_SMOKE_SCRIPT="${SMOKE_SCRIPT}" \
  MYSCOUTEE_DIAGNOSTICS_SCRIPT="${DIAGNOSTICS}" \
  MYSCOUTEE_COMPOSE_SCRIPT="${COMPOSE_SCRIPT}" \
  MYSCOUTEE_REGISTRY_STATE_DIR="${TEST_ROOT}/registry-state" \
  MYSCOUTEE_REGISTRY_KEY_DIR="${TEST_ROOT}/registry-keys" \
    bash "${QUALIFIER}" "$@"
}

SUCCESS_OUTPUT="${TEST_ROOT}/success.out"
run_qualifier restart-and-check \
  --expected-version 1.0.0 \
  --timeout-seconds 10 > "${SUCCESS_OUTPUT}"
grep -Fq 'deployment qualification passed' "${SUCCESS_OUTPUT}" \
  || fail "successful qualification did not report completion"
grep -Fqx $'systemctl\trestart myscoutee.service' "${COMMAND_LOG}" \
  || fail "restart-and-check did not restart the service"
grep -Fq $'smoke\tbase=http://127.0.0.1 start=false timeout=' "${COMMAND_LOG}" \
  || fail "qualification did not invoke the packaged smoke contract"
for required_container in server-stun-1 mongodb redis minio registry-demo payment-simulator mcp myscoutee nginx; do
  grep -Fq $'docker\tinspect '"${required_container}"' --format ' \
    "${COMMAND_LOG}" \
    || fail "qualification did not wait for ${required_container} health"
done
grep -Fq 'node is uninitialized' "${SUCCESS_OUTPUT}" \
  || fail "uninitialized registry state was not reported"

: > "${COMMAND_LOG}"
printf 'test-public-key' > "${TEST_ROOT}/registry-keys/deployment-public-key.der"
IDENTITY_OUTPUT="${TEST_ROOT}/identity.out"
run_qualifier check \
  --expected-version 1.0.0 \
  --timeout-seconds 10 > "${IDENTITY_OUTPUT}"
grep -Fq 'identity is initialized but unregistered' "${IDENTITY_OUTPUT}" \
  || fail "initialized registry identity was not reported"

cat > "${TEST_ROOT}/registry-state/deployment-state.json" <<'JSON'
{"deployment_id":"dep_0123456789abcdef0123456789abcdef"}
JSON
REGISTERED_OUTPUT="${TEST_ROOT}/registered.out"
run_qualifier check \
  --expected-version 1.0.0 \
  --timeout-seconds 10 > "${REGISTERED_OUTPUT}"
grep -Fq 'deployment code: dep_0123456789abcdef0123456789abcdef' \
  "${REGISTERED_OUTPUT}" \
  || fail "registered deployment state was not reported"

: > "${COMMAND_LOG}"
RESTART_OUTPUT="${TEST_ROOT}/restart-loop.out"
if QUALIFICATION_TEST_RESTARTING=true \
    run_qualifier check \
      --expected-version 1.0.0 \
      --timeout-seconds 10 > "${RESTART_OUTPUT}" 2>&1; then
  fail "restart-looping deployment passed qualification"
fi
grep -Fq $'systemctl\tstop myscoutee.service' "${COMMAND_LOG}" \
  || fail "qualification failure did not stop the service by default"
grep -Fq $'journalctl\t-u myscoutee.service' "${COMMAND_LOG}" \
  || fail "qualification failure did not collect journal diagnostics"

: > "${COMMAND_LOG}"
if QUALIFICATION_TEST_I18N_VALID=false \
    run_qualifier check \
      --expected-version 1.0.0 \
      --timeout-seconds 10 \
      --leave-running-on-failure >/dev/null 2>&1; then
  fail "invalid i18n response passed qualification"
fi
if grep -Fq $'systemctl\tstop myscoutee.service' "${COMMAND_LOG}"; then
  fail "--leave-running-on-failure still stopped the service"
fi

: > "${COMMAND_LOG}"
if QUALIFICATION_TEST_VERSION=1.0.1 \
    run_qualifier check \
      --expected-version 1.0.0 \
      --timeout-seconds 10 >/dev/null 2>&1; then
  fail "installed package version mismatch passed qualification"
fi

echo "Deployment qualification tests passed."
