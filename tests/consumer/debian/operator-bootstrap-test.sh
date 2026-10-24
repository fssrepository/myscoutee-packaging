#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}"
HELPER="${REPO_ROOT}/build/scripts/ensure-operator-bootstrap.sh"
SECRETS_TEMPLATE="${REPO_ROOT}/config/packaging/templates/myscoutee.secrets.env"
PACKAGED_COMPOSE="${REPO_ROOT}/config/packaging/compose/docker-compose.production.yml"
SOURCE_COMPOSE="${REPO_ROOT}/server/docker-compose-prod.yml"
SOURCE_SECRETS_EXAMPLE="${REPO_ROOT}/server/.env.secrets.example"
TEST_ROOT="$(mktemp -d /tmp/myscoutee-operator-bootstrap-test.XXXXXX)"

cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT
mkdir -p "${TEST_ROOT}/debian"
python3 "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py" "${REPO_ROOT}/packaging" "${TEST_ROOT}/debian" --hook all
POSTINST="${TEST_ROOT}/debian/postinst"

fail() {
  echo "operator bootstrap test failed: $*" >&2
  exit 1
}

create_fixture() {
  local name="$1"
  local operator_user="${2:-}"
  local fixture="${TEST_ROOT}/${name}"

  mkdir -p "${fixture}"
  printf 'OPERATOR_USER=%s\n' "${operator_user}" > "${fixture}/myscoutee.env"
  cp "${SECRETS_TEMPLATE}" "${fixture}/myscoutee.secrets.env"
  chmod 0600 "${fixture}/myscoutee.secrets.env"
  printf '%s' "${fixture}"
}

read_value() {
  local key="$1"
  local file="$2"
  sed -n "s/^${key}=//p" "${file}" | tail -n 1
}

run_helper() {
  local fixture="$1"
  MYSCOUTEE_BOOTSTRAP_ENV_FILE="${fixture}/myscoutee.env" \
  MYSCOUTEE_BOOTSTRAP_SECRETS_FILE="${fixture}/myscoutee.secrets.env" \
  MYSCOUTEE_BOOTSTRAP_OWNER_UID="$(id -u)" \
  MYSCOUTEE_BOOTSTRAP_OWNER_GID="$(id -g)" \
    "${HELPER}"
}

[[ -x "${HELPER}" ]] || fail "bootstrap helper is not executable"

FIRST_FIXTURE="$(create_fixture first)"
FIRST_OUTPUT="$(run_helper "${FIRST_FIXTURE}")"
FIRST_EMAIL="$(sed -n 's/^  Email: //p' <<< "${FIRST_OUTPUT}")"
FIRST_PASSWORD="$(sed -n 's/^  Password: //p' <<< "${FIRST_OUTPUT}")"
[[ "${FIRST_EMAIL}" =~ ^operator-[0-9a-f]{24}@deployment\.invalid$ ]] \
  || fail "generated Operator email is invalid"
[[ "${FIRST_PASSWORD}" =~ ^[0-9a-f]{64}$ ]] \
  || fail "generated Operator password is not a 256-bit printable value"
grep -Fq \
  'The password remains valid for later Operator logins until you explicitly replace or disable it.' \
  <<< "${FIRST_OUTPUT}" \
  || fail "bootstrap output does not explain that shown-once is not one-time-use"

STORED_EMAIL="$(read_value OPERATOR_USER "${FIRST_FIXTURE}/myscoutee.env")"
STORED_BOOTSTRAP_EMAIL="$(
  read_value \
    OPERATOR_BOOTSTRAP_EMAIL \
    "${FIRST_FIXTURE}/myscoutee.secrets.env"
)"
STORED_HASH="$(
  read_value \
    OPERATOR_BOOTSTRAP_PASSWORD_SHA256 \
    "${FIRST_FIXTURE}/myscoutee.secrets.env"
)"
EXPECTED_HASH="$(printf '%s' "${FIRST_PASSWORD}" | sha256sum | awk '{ print $1 }')"
[[ "${STORED_EMAIL}" == "${FIRST_EMAIL}" ]] \
  || fail "generated Operator email was not stored"
[[ "${STORED_BOOTSTRAP_EMAIL}" == "${FIRST_EMAIL}" ]] \
  || fail "bootstrap digest was not bound to its generated Operator subject"
[[ "${STORED_HASH}" == "${EXPECTED_HASH}" ]] \
  || fail "only the expected bootstrap password digest was not stored"
[[ "$(stat -c '%a' "${FIRST_FIXTURE}/myscoutee.secrets.env")" == "600" ]] \
  || fail "bootstrap password digest file is not root-only mode"
[[ "$(stat -c '%u:%g' "${FIRST_FIXTURE}/myscoutee.env")" \
      == "$(id -u):$(id -g)" \
  && "$(stat -c '%u:%g' "${FIRST_FIXTURE}/myscoutee.secrets.env")" \
      == "$(id -u):$(id -g)" ]] \
  || fail "bootstrap helper did not enforce the configured file owner"
if grep -Fq -- "${FIRST_PASSWORD}" \
    "${FIRST_FIXTURE}/myscoutee.env" \
    "${FIRST_FIXTURE}/myscoutee.secrets.env"; then
  fail "plaintext bootstrap password was persisted"
fi

FIRST_ENV_DIGEST="$(sha256sum "${FIRST_FIXTURE}/myscoutee.env")"
FIRST_SECRETS_DIGEST="$(sha256sum "${FIRST_FIXTURE}/myscoutee.secrets.env")"
SECOND_OUTPUT="$(run_helper "${FIRST_FIXTURE}")"
[[ -z "${SECOND_OUTPUT}" ]] || fail "upgrade reprinted the bootstrap credential"
[[ "$(sha256sum "${FIRST_FIXTURE}/myscoutee.env")" == "${FIRST_ENV_DIGEST}" ]] \
  || fail "upgrade changed the generated Operator identity"
[[ "$(sha256sum "${FIRST_FIXTURE}/myscoutee.secrets.env")" == "${FIRST_SECRETS_DIGEST}" ]] \
  || fail "upgrade rotated the bootstrap password digest"

PRINT_FAILURE_FIXTURE="$(create_fixture print-failure)"
if run_helper "${PRINT_FAILURE_FIXTURE}" \
    >/dev/full \
    2>"${PRINT_FAILURE_FIXTURE}/failure"; then
  fail "bootstrap digest was committed even though credential output failed"
fi
[[ "$(read_value OPERATOR_USER "${PRINT_FAILURE_FIXTURE}/myscoutee.env")" \
      =~ ^operator-[0-9a-f]{24}@deployment\.invalid$ ]] \
  || fail "failed credential output did not preserve its generated subject"
[[ -z "$(
  read_value \
    OPERATOR_BOOTSTRAP_PASSWORD_SHA256 \
    "${PRINT_FAILURE_FIXTURE}/myscoutee.secrets.env"
)" ]] || fail "failed credential output activated an unrecoverable digest"
PRINT_RECOVERY_OUTPUT="$(
  run_helper "${PRINT_FAILURE_FIXTURE}" \
    2>"${PRINT_FAILURE_FIXTURE}/recovery-warning"
)"
PRINT_RECOVERY_PASSWORD="$(
  sed -n 's/^  Password: //p' <<< "${PRINT_RECOVERY_OUTPUT}"
)"
[[ "${PRINT_RECOVERY_PASSWORD}" =~ ^[0-9a-f]{64}$ ]] \
  || fail "interrupted credential output was not recoverable"
grep -q 'Incomplete Operator bootstrap state detected' \
  "${PRINT_FAILURE_FIXTURE}/recovery-warning" \
  || fail "recovered bootstrap state was not reported explicitly"
[[ "$(
  read_value \
    OPERATOR_BOOTSTRAP_PASSWORD_SHA256 \
    "${PRINT_FAILURE_FIXTURE}/myscoutee.secrets.env"
)" == "$(printf '%s' "${PRINT_RECOVERY_PASSWORD}" | sha256sum | awk '{ print $1 }')" ]] \
  || fail "recovered credential was not the one activated"

PRECONFIGURED_FIXTURE="$(create_fixture preconfigured owner@example.invalid)"
PRECONFIGURED_OUTPUT="$(run_helper "${PRECONFIGURED_FIXTURE}")"
[[ -z "${PRECONFIGURED_OUTPUT}" ]] \
  || fail "preconfigured Operator identity received an unwanted local credential"
[[ "$(read_value OPERATOR_USER "${PRECONFIGURED_FIXTURE}/myscoutee.env")" \
      == "owner@example.invalid" ]] \
  || fail "preconfigured Operator identity was replaced"
[[ -z "$(
  read_value \
    OPERATOR_BOOTSTRAP_EMAIL \
    "${PRECONFIGURED_FIXTURE}/myscoutee.secrets.env"
)" ]] || fail "preconfigured Operator identity received a bootstrap subject"
[[ -z "$(
  read_value \
    OPERATOR_BOOTSTRAP_PASSWORD_SHA256 \
    "${PRECONFIGURED_FIXTURE}/myscoutee.secrets.env"
)" ]] || fail "preconfigured Operator identity received a password digest"

INTERRUPTED_FIXTURE="$(
  create_fixture interrupted operator-0123456789abcdef01234567@deployment.invalid
)"
INTERRUPTED_OUTPUT="$(run_helper "${INTERRUPTED_FIXTURE}")"
[[ "$(sed -n 's/^  Email: //p' <<< "${INTERRUPTED_OUTPUT}")" \
      == "operator-0123456789abcdef01234567@deployment.invalid" ]] \
  || fail "interrupted initialization did not preserve its generated identity"
[[ "$(
  read_value \
    OPERATOR_BOOTSTRAP_EMAIL \
    "${INTERRUPTED_FIXTURE}/myscoutee.secrets.env"
)" == "operator-0123456789abcdef01234567@deployment.invalid" ]] \
  || fail "interrupted initialization did not persist its bootstrap subject"
[[ "$(
  read_value \
    OPERATOR_BOOTSTRAP_PASSWORD_SHA256 \
    "${INTERRUPTED_FIXTURE}/myscoutee.secrets.env"
)" =~ ^[0-9a-f]{64}$ ]] \
  || fail "interrupted initialization did not complete its password digest"

EMAIL_ONLY_FIXTURE="$(
  create_fixture email-only operator-fedcba987654321001234567@deployment.invalid
)"
sed -i \
  's/^OPERATOR_BOOTSTRAP_EMAIL=.*/OPERATOR_BOOTSTRAP_EMAIL=operator-fedcba987654321001234567@deployment.invalid/' \
  "${EMAIL_ONLY_FIXTURE}/myscoutee.secrets.env"
EMAIL_ONLY_OUTPUT="$(run_helper "${EMAIL_ONLY_FIXTURE}")"
[[ "$(sed -n 's/^  Email: //p' <<< "${EMAIL_ONLY_OUTPUT}")" \
      == "operator-fedcba987654321001234567@deployment.invalid" ]] \
  || fail "stored bootstrap subject without a hash did not complete"
[[ "$(
  read_value \
    OPERATOR_BOOTSTRAP_PASSWORD_SHA256 \
    "${EMAIL_ONLY_FIXTURE}/myscoutee.secrets.env"
)" =~ ^[0-9a-f]{64}$ ]] \
  || fail "stored bootstrap subject without a hash did not receive its digest"

ORPHAN_FIXTURE="$(
  create_fixture orphan operator-aaaaaaaaaaaaaaaaaaaaaaaa@deployment.invalid
)"
ORPHAN_HASH="$(printf 'a%.0s' {1..64})"
sed -i \
  "s/^OPERATOR_BOOTSTRAP_PASSWORD_SHA256=.*/OPERATOR_BOOTSTRAP_PASSWORD_SHA256=${ORPHAN_HASH}/" \
  "${ORPHAN_FIXTURE}/myscoutee.secrets.env"
if run_helper "${ORPHAN_FIXTURE}" \
    >"${ORPHAN_FIXTURE}/output" \
    2>"${ORPHAN_FIXTURE}/warning"; then
  fail "orphan digest with no Operator identity did not fail closed"
fi
[[ ! -s "${ORPHAN_FIXTURE}/output" ]] || fail "orphan digest caused credential output"
[[ "$(read_value OPERATOR_USER "${ORPHAN_FIXTURE}/myscoutee.env")" \
      == "operator-aaaaaaaaaaaaaaaaaaaaaaaa@deployment.invalid" ]] \
  || fail "orphan digest changed the current Operator identity"
[[ -z "$(
  read_value \
    OPERATOR_BOOTSTRAP_EMAIL \
    "${ORPHAN_FIXTURE}/myscoutee.secrets.env"
)" ]] || fail "orphan digest was rebound to an unstored subject"
[[ "$(
  read_value \
    OPERATOR_BOOTSTRAP_PASSWORD_SHA256 \
    "${ORPHAN_FIXTURE}/myscoutee.secrets.env"
)" == "${ORPHAN_HASH}" ]] || fail "orphan digest was replaced"
grep -q 'preserving existing state without rebinding' \
  "${ORPHAN_FIXTURE}/warning" \
  || fail "orphan state did not produce an actionable warning"

MISMATCH_FIXTURE="${TEST_ROOT}/mismatch"
cp -a "${FIRST_FIXTURE}" "${MISMATCH_FIXTURE}"
sed -i \
  's/^OPERATOR_USER=.*/OPERATOR_USER=operator-bbbbbbbbbbbbbbbbbbbbbbbb@deployment.invalid/' \
  "${MISMATCH_FIXTURE}/myscoutee.env"
MISMATCH_ENV_DIGEST="$(sha256sum "${MISMATCH_FIXTURE}/myscoutee.env")"
MISMATCH_SECRETS_DIGEST="$(sha256sum "${MISMATCH_FIXTURE}/myscoutee.secrets.env")"
if ! run_helper "${MISMATCH_FIXTURE}" \
    >"${MISMATCH_FIXTURE}/output" \
    2>"${MISMATCH_FIXTURE}/warning"; then
  fail "deliberate OPERATOR_USER change made an idempotent package upgrade fail"
fi
[[ ! -s "${MISMATCH_FIXTURE}/output" ]] \
  || fail "subject mismatch reprinted a credential"
[[ "$(sha256sum "${MISMATCH_FIXTURE}/myscoutee.env")" \
      == "${MISMATCH_ENV_DIGEST}" ]] \
  || fail "subject mismatch rebound the current Operator identity"
[[ "$(sha256sum "${MISMATCH_FIXTURE}/myscoutee.secrets.env")" \
      == "${MISMATCH_SECRETS_DIGEST}" ]] \
  || fail "subject mismatch rebound or rotated bootstrap state"
grep -q 'local bootstrap login is disabled and existing state is preserved' \
  "${MISMATCH_FIXTURE}/warning" \
  || fail "subject mismatch did not report the disabled local credential"

INVALID_FIXTURE="$(create_fixture invalid)"
sed -i \
  's/^OPERATOR_BOOTSTRAP_PASSWORD_SHA256=.*/OPERATOR_BOOTSTRAP_PASSWORD_SHA256=invalid/' \
  "${INVALID_FIXTURE}/myscoutee.secrets.env"
if run_helper "${INVALID_FIXTURE}" >/dev/null 2>&1; then
  fail "malformed bootstrap digest was accepted"
fi
[[ -z "$(read_value OPERATOR_USER "${INVALID_FIXTURE}/myscoutee.env")" ]] \
  || fail "malformed digest caused identity rotation"

grep -Fq 'MYSCOUTEE_BOOTSTRAP_ENV_FILE=${PACKAGE_ETC}/${PACKAGE_NAME}.env \' \
  "${POSTINST}" \
  || fail "postinst does not invoke bootstrap against the installed environment"
grep -Fq 'MYSCOUTEE_BOOTSTRAP_SECRETS_FILE=${PACKAGE_ETC}/${PACKAGE_NAME}.secrets.env \' \
  "${POSTINST}" \
  || fail "postinst does not invoke bootstrap against the installed secrets"
grep -Fq 'MYSCOUTEE_BOOTSTRAP_OWNER_UID=0 \' "${POSTINST}" \
  || fail "postinst does not enforce root ownership for bootstrap files"
grep -Fq 'MYSCOUTEE_BOOTSTRAP_OWNER_GID=0 \' "${POSTINST}" \
  || fail "postinst does not enforce the root group for bootstrap files"
grep -Fq 'shown-once deployment-local Operator credential' "${REPO_ROOT}/config/packaging/templates/install-policy.json" \
  || fail "postinst does not distinguish shown-once from single-use"
grep -Fq 'The password itself is not single-use' "${REPO_ROOT}/config/packaging/templates/install-policy.json" \
  || fail "postinst does not explain ongoing Operator bootstrap login"
if grep -Fq \
  'Add /etc/myscoutee/firebase-service-account.json' \
  "${POSTINST}"; then
  fail "postinst still requires a legacy external Firebase credential before login"
fi
grep -Fxq 'OPERATOR_BOOTSTRAP_EMAIL=' "${SOURCE_SECRETS_EXAMPLE}" \
  || fail "source production secrets example lacks the bootstrap subject placeholder"
grep -Fxq 'OPERATOR_BOOTSTRAP_PASSWORD_SHA256=' "${SOURCE_SECRETS_EXAMPLE}" \
  || fail "source production secrets example lacks the bootstrap digest placeholder"

render_and_assert_bootstrap() {
  local name="$1"
  local compose_source="$2"
  local stage="${TEST_ROOT}/${name}-compose"
  local rendered

  mkdir -p "${stage}/projects/profile/secrets"
  cp "${compose_source}" "${stage}/docker-compose-prod.yml"
  cp "${REPO_ROOT}/config/packaging/compose/docker-compose.production-replicaset.yml" "${stage}/"
  cp "${REPO_ROOT}/server/"docker-compose{.replicaset,-stun}.yml "${stage}/"
  cp "${FIRST_FIXTURE}/myscoutee.secrets.env" "${stage}/.env.secrets"
  cp "${REPO_ROOT}/config/packaging/templates/myscoutee.env" \
    "${stage}/runtime.env"
  sed -i \
    "s|^OPERATOR_USER=.*|OPERATOR_USER=${FIRST_EMAIL}|" \
    "${stage}/runtime.env"
  printf '{}\n' \
    > "${stage}/projects/profile/secrets/firebase-service-account.json"

  rendered="$(
    docker compose \
      --project-directory "${stage}" \
      --env-file "${stage}/runtime.env" \
      -f "${stage}/docker-compose-prod.yml" \
      config --format json
  )" || fail "${name} production Compose did not render"

  jq -e \
    --arg email "${FIRST_EMAIL}" \
    --arg digest "${STORED_HASH}" \
    '
      .services.profilemanagement.environment.OPERATOR_USER == $email
      and .services.profilemanagement.environment.OPERATOR_BOOTSTRAP_EMAIL
        == $email
      and .services.profilemanagement.environment.OPERATOR_BOOTSTRAP_PASSWORD_SHA256
        == $digest
    ' <<< "${rendered}" >/dev/null \
    || fail "${name} production Compose did not pass the exact bootstrap subject and digest"
  if grep -Fq "${FIRST_PASSWORD}" <<< "${rendered}"; then
    fail "${name} production Compose rendered the plaintext bootstrap password"
  fi
}

if command -v docker >/dev/null 2>&1 \
  && command -v jq >/dev/null 2>&1 \
  && docker compose version >/dev/null 2>&1; then
  render_and_assert_bootstrap packaged "${PACKAGED_COMPOSE}"
  render_and_assert_bootstrap source "${SOURCE_COMPOSE}"
fi

echo "operator bootstrap tests passed"
