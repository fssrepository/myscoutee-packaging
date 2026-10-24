#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}"
TEST_ROOT="$(mktemp -d /tmp/myscoutee-removal-contract-test.XXXXXX)"
FAKE_BIN="${TEST_ROOT}/bin"
COMMAND_LOG="${TEST_ROOT}/commands.log"

cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT
mkdir -p "${TEST_ROOT}/debian"
python3 "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py" "${REPO_ROOT}/packaging" "${TEST_ROOT}/debian" --hook all
POSTINST="${TEST_ROOT}/debian/postinst"
POSTRM="${TEST_ROOT}/debian/postrm"
POSTRM="${TEST_ROOT}/postrm"
python3 "${REPO_ROOT}/config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py" "${REPO_ROOT}/packaging" "$POSTRM"
export DPKG_MAINTSCRIPT_PACKAGE=myscoutee

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

for abort_action in abort-upgrade abort-remove abort-deconfigure; do
  if ! bash "${POSTINST}" "${abort_action}" >/dev/null 2>&1; then
    fail "postinst does not safely accept ${abort_action}"
  fi
done
if bash "${POSTINST}" unsupported-action >/dev/null 2>&1; then
  fail "postinst accepted an unsupported maintainer-script action"
fi

install -d "${FAKE_BIN}"
: > "${COMMAND_LOG}"

cat > "${FAKE_BIN}/systemctl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'systemctl\t%s\n' "$*" >> "${REMOVAL_CONTRACT_LOG:?}"
SCRIPT

cat > "${FAKE_BIN}/rm" <<'SCRIPT'
#!/usr/bin/env bash
printf 'rm\t%s\n' "$*" >> "${REMOVAL_CONTRACT_LOG:?}"
SCRIPT

cat > "${FAKE_BIN}/docker" <<'SCRIPT'
#!/usr/bin/env bash
printf 'docker\t%s\n' "$*" >> "${REMOVAL_CONTRACT_LOG:?}"
case "${1:-} ${2:-}" in
  "images --format")
    cat <<'IMAGES'
myscoutee-api:0.9.0-prod
myscoutee-api:1.0.0-dev
myscoutee-nginx:0.9.0-base
myscoutee-nginx:1.0.0-prod
myscoutee-minio:audit-final
myscoutee-registry:1.0.0-prod
myscoutee-payment-simulator:1.0.0-prod
myscoutee-mcp:1.0.0-prod
myscoutee-template-api:1.0.0-prod
mongo:8.0.4
redis:8.6.1-alpine
unrelated-api:1.0.0-prod
IMAGES
    ;;
  "volume inspect"|"volume rm"|"image rm")
    exit 0
    ;;
esac
SCRIPT

chmod 0755 \
  "${FAKE_BIN}/systemctl" \
  "${FAKE_BIN}/rm" \
  "${FAKE_BIN}/docker"

ENV_FILE="${TEST_ROOT}/myscoutee.env"
cat > "${ENV_FILE}" <<'ENV'
REGISTRY_DEMO_VOLUME_NAME="custom-registry-demo-data-v2"
REGISTRY_DEMO_CLIENT_VOLUME_NAME='custom-registry-demo-client-v2'
PAYMENT_SIMULATOR_VOLUME_NAME=custom-payment-simulator-v2
ENV

run_postrm() {
  local action="$1"

  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  REMOVAL_CONTRACT_LOG="${COMMAND_LOG}" \
  MYSCOUTEE_POSTRM_ENV_FILE="${ENV_FILE}" \
    bash "${POSTRM}" "${action}"
}

run_postrm remove
if grep -Eq '^docker\t(volume rm|image rm)' "${COMMAND_LOG}"; then
  fail "normal package removal deleted a Docker volume or image"
fi
if grep -Eq '^rm\t' "${COMMAND_LOG}"; then
  fail "normal package removal deleted deployment state"
fi

: > "${COMMAND_LOG}"
run_postrm purge

for volume in \
  custom-registry-demo-data-v2 \
  custom-registry-demo-client-v2 \
  custom-payment-simulator-v2; do
  grep -Fqx "docker	volume inspect ${volume}" "${COMMAND_LOG}" \
    || fail "purge did not inspect configured volume ${volume}"
  grep -Fqx "docker	volume rm -f ${volume}" "${COMMAND_LOG}" \
    || fail "purge did not remove configured volume ${volume}"
done

for image in \
  myscoutee-api:0.9.0-prod \
  myscoutee-api:1.0.0-dev \
  myscoutee-nginx:0.9.0-base \
  myscoutee-nginx:1.0.0-prod \
  myscoutee-minio:audit-final \
  myscoutee-registry:1.0.0-prod \
  myscoutee-payment-simulator:1.0.0-prod; do
  grep -Fqx "docker	image rm -f ${image}" "${COMMAND_LOG}" \
    || fail "purge left stale managed image ${image}"
done
if grep -Eq '^docker\timage rm -f (mongo|redis|unrelated-api):' \
    "${COMMAND_LOG}"; then
  fail "purge removed an upstream or unrelated image"
fi

for path in \
  /etc/myscoutee \
  /opt/myscoutee \
  /var/lib/myscoutee \
  /var/log/myscoutee \
  /var/cache/myscoutee-update; do
  grep -Fqx "rm	-rf ${path}" "${COMMAND_LOG}" \
    || fail "purge did not remove ${path}"
done
if grep -Fq '/var/backups/myscoutee' "${COMMAND_LOG}"; then
  fail "purge deleted the external recovery archive"
fi

echo "Debian removal contract tests passed."
