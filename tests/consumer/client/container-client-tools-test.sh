#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  printf 'client-tools-test: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repository_root="$(cd -- "$script_dir/../../.." && pwd -P)"
client_source="$repository_root/build/client-tools"

for required_file in \
  forward.json \
  README.md \
  deployment.env.example \
  install.env.example \
  install.sh \
  purge.sh \
  forward-localhost.sh \
  remote-transport.sh \
  verify-release.sh; do
  [[ -f "$client_source/$required_file" ]] ||
    fail "missing client tool: $required_file"
done

[[ "$(sed -n '1p' "$repository_root/config/packaging/client-tools/.gitignore")" == "/install.env" ]] ||
  fail "install.env is not locally ignored"
git -C "$repository_root" check-ignore -q \
  config/packaging/client-tools/install.env ||
  fail "Git does not ignore the local install.env"
for local_input in install.env deployment.env tls/private.key; do
  git -C "$repository_root" check-ignore -q \
    "config/packaging/client-tools/$local_input" ||
    fail "Git does not ignore local provisioning input $local_input"
done
for local_env in install.env deployment.env; do
  [[ ! -e "$client_source/$local_env" ]] ||
    fail "a real $local_env exists in the client-tools source"
  if git -C "$repository_root" ls-files --error-unmatch \
      "config/packaging/client-tools/$local_env" >/dev/null 2>&1; then
    fail "$local_env is tracked"
  fi
done
if find "$client_source" -type l -print -quit | grep -q .; then
  fail "client-tools source contains a symbolic link"
fi

grep -Fq 'REMOTE_DEB_PATH=/tmp/@@PACKAGE_NAME@@.deb' \
  "$client_source/install.env.example" ||
  fail "safe remote package path default changed"
grep -Fq 'LOCAL_FORWARD_PORTS=18443:443,18080:80' \
  "$client_source/install.env.example" ||
  fail "high-port loopback defaults changed"
grep -Fq 'ALLOW_UNSIGNED_LOCAL_PACKAGE=false' \
  "$client_source/install.env.example" ||
  fail "unsigned local package override is not safe by default"
grep -Fq 'RELEASE_PUBLIC_KEY_FINGERPRINT=' \
  "$client_source/install.env.example" ||
  fail "signed release trust input is missing"
grep -Fq 'START_SERVICE=false' "$client_source/install.env.example" ||
  fail "runtime start is not fail-closed by default"
for provisioning_key in \
  DEPLOYMENT_ENV_FILE TLS_CERTIFICATE_FILE TLS_PRIVATE_KEY_FILE; do
  grep -Eq "^${provisioning_key}=$" "$client_source/install.env.example" ||
    fail "explicit provisioning input is missing: $provisioning_key"
done
grep -Eq '^REGISTRY_SCOPE=$' "$client_source/deployment.env.example" ||
  fail "deployment env contains a default permanent scope"
grep -Eq '^REGISTRY_PUBLIC_HOSTNAME=$' \
  "$client_source/deployment.env.example" ||
  fail "deployment env contains a default public hostname"
if grep -q '^REGISTRY_LOOPBACK_PORT=' \
    "$client_source/deployment.env.example"; then
  fail "deployment env exposes the internal Registry backend"
fi
grep -Fq 'sshpass -d 9' "$client_source/remote-transport.sh" ||
  fail "password transport does not use an inherited descriptor"
grep -Fq 'SSH_ASKPASS_REQUIRE=force' "$client_source/remote-transport.sh" ||
  fail "password transport has no askpass fallback"
grep -Fq 'sudo -S -p' "$client_source/remote-transport.sh" ||
  fail "password sudo transport is missing"
grep -Fq 'sudo -n -p' "$client_source/remote-transport.sh" ||
  fail "non-interactive sudo transport is missing"
grep -Fq -- '-i "$REMOTE_KEY_FILE"' "$client_source/remote-transport.sh" ||
  fail "SSH key transport is missing"

grep -Fq \
  "/opt/@@PACKAGE_NAME@@/packaging/scripts/qualify-deployment.sh" \
  "$client_source/install.sh" ||
  fail "installer does not use package-provided qualification"
grep -Fq 'restart-and-check' "$client_source/install.sh" ||
  fail "installer does not request restart-and-check qualification"
grep -Fq 'apt-get -f install -y --no-remove' "$client_source/install.sh" ||
  fail "same-version dependency repair contract changed"
grep -Fq 'dpkg --unpack "$REMOTE_DEB_PATH"' "$client_source/install.sh" ||
  fail "same-version unpack contract changed"
grep -Fq 'TLS certificate and private key do not match' \
  "$client_source/install.sh" ||
  fail "TLS certificate/private-key matching is not enforced"
grep -Fq 'START_SERVICE=true requires all three explicit provisioning inputs' \
  "$client_source/install.sh" ||
  fail "fresh runtime start is not gated by explicit provisioning"
if grep -Eq '(^|[[:space:]])(node[[:space:]]+.*run\.mjs|run\.mjs[[:space:]])' \
    "$client_source/install.sh"; then
  fail "installer contains an executable verifier invocation"
fi

purge_commands="$(
  sed -n '/remote_transport_run_root/,/apt-get purge/p' \
    "$client_source/purge.sh"
)"
grep -Fq 'apt-get purge -y @@PACKAGE_NAME@@' \
  "$client_source/purge.sh" ||
  fail "purge does not use apt-get purge for the package"
grep -Fq 'CONFIRM_PURGE_WITH_VERIFIED_BACKUP=true' \
  "$client_source/purge.sh" ||
  fail "purge does not require verified-backup confirmation"
if grep -Eq 'rm[[:space:]]|find[[:space:]].*-delete|docker|/etc/@@PACKAGE_NAME@@|/var/lib' \
    "$client_source/purge.sh"; then
  fail "purge contains an out-of-scope data cleanup command"
fi
[[ -n "$purge_commands" ]] ||
  fail "purge remote command contract could not be inspected"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/registry-client-tools-test.XXXXXXXX")"
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

client_under_test="$work_dir/client-tools"
fake_bin="$work_dir/bin"
test_log="$work_dir/transport.log"
install_output="$work_dir/install.out"
mkdir -p "$client_under_test/verify-deployment" "$fake_bin"
cp -a "$client_source/." "$client_under_test/"
printf '%s\n' '// test-only verifier marker' \
  >"$client_under_test/verify-deployment/run.mjs"
printf '%s\n' 'not a real package' >"$work_dir/package.deb"

deployment_env="$work_dir/deployment.env"
sed \
  -e 's/^MYSCOUTEE_REGISTRY_VERSION=.*$/MYSCOUTEE_REGISTRY_VERSION=1.0.0/' \
  -e 's/^REGISTRY_PRODUCTION_IMAGE=.*$/REGISTRY_PRODUCTION_IMAGE=@@PACKAGE_NAME@@:1.0.0-prod/' \
  -e 's/^REGISTRY_NGINX_PRODUCTION_IMAGE=.*$/REGISTRY_NGINX_PRODUCTION_IMAGE=@@NGINX_IMAGE@@:1.0.0-prod/' \
  -e 's/^REGISTRY_SCOPE=.*$/REGISTRY_SCOPE=production:registry-test/' \
  -e 's/^REGISTRY_PUBLIC_HOSTNAME=.*$/REGISTRY_PUBLIC_HOSTNAME=registry.test/' \
  "$client_source/deployment.env.example" >"$deployment_env"
printf '%s\n' '# PERMANENT_SECRET_SENTINEL' >>"$deployment_env"
chmod 0600 "$deployment_env"

tls_private_key="$work_dir/tls-private.key"
tls_certificate="$work_dir/tls-certificate.pem"
openssl req \
  -x509 \
  -newkey rsa:2048 \
  -nodes \
  -days 1 \
  -subj '/CN=registry.test' \
  -addext 'subjectAltName=DNS:registry.test' \
  -keyout "$tls_private_key" \
  -out "$tls_certificate" >/dev/null 2>&1
chmod 0600 "$tls_private_key"
chmod 0644 "$tls_certificate"

config_file="$work_dir/install.env"
printf '%s\n' \
  'REMOTE_HOST=registry.test' \
  'REMOTE_USER=operator' \
  'REMOTE_PORT=22' \
  'REMOTE_KEY_FILE=' \
  'REMOTE_PASSWORD=' \
  'REMOTE_SUDO_PASSWORD=' \
  'REMOTE_DEB_PATH=/tmp/@@PACKAGE_NAME@@.deb' \
  'REMOTE_HOST_KEY_CHECKING=yes' \
  'REMOTE_CONNECT_TIMEOUT_SECONDS=2' \
  'REMOTE_SSH_OPTIONS=' \
  'RUN_APT_UPDATE=false' \
  'QUALIFY_TIMEOUT_SECONDS=47' \
  'ALLOW_DOWNGRADE=false' \
  'START_SERVICE=true' \
  "DEPLOYMENT_ENV_FILE=$deployment_env" \
  "TLS_CERTIFICATE_FILE=$tls_certificate" \
  "TLS_PRIVATE_KEY_FILE=$tls_private_key" \
  'CONFIRM_PURGE_WITH_VERIFIED_BACKUP=true' \
  'ALLOW_UNSIGNED_LOCAL_PACKAGE=true' \
  'VERIFY_DEPLOYMENT_URL=https://registry.test' \
  >"$config_file"
chmod 0600 "$config_file"

install_only_config="$work_dir/install-only.env"
sed \
  -e 's/^START_SERVICE=true$/START_SERVICE=false/' \
  -e 's|^DEPLOYMENT_ENV_FILE=.*$|DEPLOYMENT_ENV_FILE=|' \
  -e 's|^TLS_CERTIFICATE_FILE=.*$|TLS_CERTIFICATE_FILE=|' \
  -e 's|^TLS_PRIVATE_KEY_FILE=.*$|TLS_PRIVATE_KEY_FILE=|' \
  "$config_file" >"$install_only_config"
chmod 0600 "$install_only_config"

missing_provisioning_config="$work_dir/missing-provisioning.env"
sed \
  -e 's|^DEPLOYMENT_ENV_FILE=.*$|DEPLOYMENT_ENV_FILE=|' \
  -e 's|^TLS_CERTIFICATE_FILE=.*$|TLS_CERTIFICATE_FILE=|' \
  -e 's|^TLS_PRIVATE_KEY_FILE=.*$|TLS_PRIVATE_KEY_FILE=|' \
  "$config_file" >"$missing_provisioning_config"
chmod 0600 "$missing_provisioning_config"

unsigned_refused_config="$work_dir/unsigned-refused.env"
sed 's/^ALLOW_UNSIGNED_LOCAL_PACKAGE=true$/ALLOW_UNSIGNED_LOCAL_PACKAGE=false/' \
  "$config_file" >"$unsigned_refused_config"
chmod 0600 "$unsigned_refused_config"

printf '%s\n' \
  '#!/bin/sh' \
  'case "${3:-}" in' \
  '  Package) printf "%s\n" @@PACKAGE_NAME@@ ;;' \
  '  Version) printf "%s\n" 1.0.0 ;;' \
  '  Architecture) printf "%s\n" amd64 ;;' \
  '  *) exit 2 ;;' \
  'esac' \
  >"$fake_bin/dpkg-deb"

printf '%s\n' \
  '#!/bin/sh' \
  'case "${1:-}" in' \
  '  --validate-version) exit 0 ;;' \
  '  --compare-versions) exit 1 ;;' \
  '  *) exit 2 ;;' \
  'esac' \
  >"$fake_bin/dpkg"

printf '%s\n' \
  '#!/bin/sh' \
  ': "${TEST_TRANSPORT_LOG:?}"' \
  'printf "scp" >>"$TEST_TRANSPORT_LOG"' \
  'for argument in "$@"; do printf " <%s>" "$argument" >>"$TEST_TRANSPORT_LOG"; done' \
  'printf "\n" >>"$TEST_TRANSPORT_LOG"' \
  >"$fake_bin/scp"

printf '%s\n' \
  '#!/bin/sh' \
  ': "${TEST_TRANSPORT_LOG:?}"' \
  'printf "ssh" >>"$TEST_TRANSPORT_LOG"' \
  'for argument in "$@"; do printf " <%s>" "$argument" >>"$TEST_TRANSPORT_LOG"; done' \
  'printf "\n" >>"$TEST_TRANSPORT_LOG"' \
  'case "$*" in' \
  '  *Status-Abbrev*)' \
  '    if [ "${TEST_PACKAGE_STILL_INSTALLED:-false}" = true ]; then' \
  '      printf "%s\n" ii' \
  '      exit 0' \
  '    fi' \
  '    exit 1' \
  '    ;;' \
  '  *mktemp*d*@@PACKAGE_NAME@@-provision*)' \
  '    printf "%s\n" /tmp/@@PACKAGE_NAME@@-provision.ABC123' \
  '    ;;' \
  '  *systemctl*is-active*)' \
  '    [ "${TEST_SERVICE_ACTIVE:-false}" = true ]' \
  '    ;;' \
  '  *dpkg-query*Version*)' \
  '    [ -z "${TEST_INSTALLED_VERSION:-}" ] || printf "%s\n" "$TEST_INSTALLED_VERSION"' \
  '    ;;' \
  'esac' \
  >"$fake_bin/ssh"

printf '%s\n' \
  '#!/bin/sh' \
  ': "${TEST_TRANSPORT_LOG:?}"' \
  'printf "node" >>"$TEST_TRANSPORT_LOG"' \
  'for argument in "$@"; do printf " <%s>" "$argument" >>"$TEST_TRANSPORT_LOG"; done' \
  'printf "\n" >>"$TEST_TRANSPORT_LOG"' \
  'exit 99' \
  >"$fake_bin/node"
chmod 0755 "$fake_bin"/*

run_install() {
  local installed_version="$1"
  local service_active="${2:-false}"
  local selected_config="${3:-$config_file}"
  : >"$test_log"
  CONFIG_FILE="$selected_config" \
  PATH="$fake_bin:$PATH" \
  TEST_TRANSPORT_LOG="$test_log" \
  TEST_INSTALLED_VERSION="$installed_version" \
  TEST_SERVICE_ACTIVE="$service_active" \
    "$client_under_test/install.sh" "$work_dir/package.deb" \
      >"$install_output" 2>&1
}

: >"$test_log"
if CONFIG_FILE="$unsigned_refused_config" \
    PATH="$fake_bin:$PATH" \
    TEST_TRANSPORT_LOG="$test_log" \
    "$client_under_test/install.sh" "$work_dir/package.deb" \
      >/dev/null 2>&1; then
  fail "unsigned package was accepted without the explicit local override"
fi
[[ ! -s "$test_log" ]] ||
  fail "unsigned package reached remote transport before refusal"

unsafe_path_config="$work_dir/unsafe-path.env"
sed 's|^REMOTE_DEB_PATH=.*$|REMOTE_DEB_PATH=/var/tmp/package.deb|' \
  "$config_file" >"$unsafe_path_config"
chmod 0600 "$unsafe_path_config"
: >"$test_log"
if CONFIG_FILE="$unsafe_path_config" \
    PATH="$fake_bin:$PATH" \
    TEST_TRANSPORT_LOG="$test_log" \
    "$client_under_test/install.sh" "$work_dir/package.deb" \
      >/dev/null 2>&1; then
  fail "remote package path outside direct /tmp was accepted"
fi
[[ ! -s "$test_log" ]] ||
  fail "unsafe remote package path reached remote transport"

: >"$test_log"
if CONFIG_FILE="$missing_provisioning_config" \
    PATH="$fake_bin:$PATH" \
    TEST_TRANSPORT_LOG="$test_log" \
    TEST_INSTALLED_VERSION="" \
    TEST_SERVICE_ACTIVE=false \
    "$client_under_test/install.sh" "$work_dir/package.deb" \
      >/dev/null 2>&1; then
  fail "fresh runtime start was accepted without explicit provisioning"
fi
if grep -Eq '^scp|apt-get|qualify-deployment' "$test_log"; then
  fail "fresh runtime start mutated the host before provisioning refusal"
fi

run_install "" false "$install_only_config"
grep -Fq \
  "'apt-get' 'install' '-y' '/tmp/@@PACKAGE_NAME@@.deb'" \
  "$test_log" ||
  fail "fresh install did not use apt-get install with the uploaded package"
grep -Fq \
  "'rm' '-f' '--' '/tmp/@@PACKAGE_NAME@@.deb'" \
  "$test_log" ||
  fail "fresh install did not remove the uploaded temporary package"
if grep -Fq "'dpkg' '--unpack'" "$test_log"; then
  fail "fresh install unexpectedly used same-version unpack"
fi
if grep -Fq 'qualify-deployment.sh' "$test_log"; then
  fail "install-only fresh flow started or qualified the runtime"
fi
grep -Fq 'Package installed without starting or restarting the Registry.' \
  "$install_output" ||
  fail "install-only fresh flow did not print fail-closed state"
if grep -Fq 'node' "$test_log"; then
  fail "external verifier ran automatically after install-only fresh flow"
fi

run_install "" false "$config_file"
grep -Fq \
  "'apt-get' 'install' '-y' '/tmp/@@PACKAGE_NAME@@.deb'" \
  "$test_log" ||
  fail "provisioned fresh install did not use apt-get install"
grep -Fq \
  "'install' '-o' 'root' '-g' 'root' '-m' '0600' '/tmp/@@PACKAGE_NAME@@-provision.ABC123/deployment.env' '/etc/@@PACKAGE_NAME@@/registry.env'" \
  "$test_log" ||
  fail "deployment env was not installed with protected ownership and mode"
grep -Fq \
  "'install' '-o' 'root' '-g' 'root' '-m' '0600' '/tmp/@@PACKAGE_NAME@@-provision.ABC123/privkey.pem' '/etc/@@PACKAGE_NAME@@/tls/privkey.pem'" \
  "$test_log" ||
  fail "TLS private key was not installed with protected ownership and mode"
grep -Fq \
  "'/opt/@@PACKAGE_NAME@@/packaging/scripts/qualify-deployment.sh' 'restart-and-check' '--expected-version' '1.0.0' '--timeout-seconds' '47'" \
  "$test_log" ||
  fail "provisioned fresh install did not invoke exact qualification"
if grep -Fq 'PERMANENT_SECRET_SENTINEL' "$test_log"; then
  fail "deployment env content entered process arguments or logs"
fi
if grep -Fq 'node' "$test_log"; then
  fail "external verifier ran automatically after provisioned fresh install"
fi
grep -Fq 'External deployment verification was not run automatically.' \
  "$install_output" ||
  fail "installer did not state that verification remains external"
grep -Fq 'node "' "$install_output" ||
  fail "installer did not print the separate verifier command"

run_install "1.0.0" true "$missing_provisioning_config"
grep -Fq "'dpkg' '--unpack' '/tmp/@@PACKAGE_NAME@@.deb'" \
  "$test_log" ||
  fail "same-version install did not unpack the new payload"
grep -Fq "'apt-get' '-f' 'install' '-y' '--no-remove'" \
  "$test_log" ||
  fail "same-version install did not use no-remove dependency repair"
if grep -Fq \
    "'apt-get' 'install' '-y' '/tmp/@@PACKAGE_NAME@@.deb'" \
    "$test_log"; then
  fail "same-version install incorrectly used the fresh install branch"
fi
if grep -Fq 'node' "$test_log"; then
  fail "external verifier ran automatically after same-version install"
fi
if grep -Fq '@@PACKAGE_NAME@@-provision.' "$test_log"; then
  fail "active same-version reinstall unexpectedly replaced deployment inputs"
fi

: >"$test_log"
if CONFIG_FILE="$missing_provisioning_config" \
    PATH="$fake_bin:$PATH" \
    TEST_TRANSPORT_LOG="$test_log" \
    TEST_INSTALLED_VERSION=1.0.0 \
    TEST_SERVICE_ACTIVE=false \
    "$client_under_test/install.sh" "$work_dir/package.deb" \
      >/dev/null 2>&1; then
  fail "inactive installed runtime was started without explicit provisioning"
fi
if grep -q '^scp' "$test_log"; then
  fail "inactive runtime refusal happened after package upload"
fi

unconfirmed_purge_config="$work_dir/unconfirmed-purge.env"
sed \
  's/^CONFIRM_PURGE_WITH_VERIFIED_BACKUP=true$/CONFIRM_PURGE_WITH_VERIFIED_BACKUP=false/' \
  "$config_file" >"$unconfirmed_purge_config"
chmod 0600 "$unconfirmed_purge_config"
: >"$test_log"
if CONFIG_FILE="$unconfirmed_purge_config" \
    PATH="$fake_bin:$PATH" \
    TEST_TRANSPORT_LOG="$test_log" \
    "$client_under_test/purge.sh" >/dev/null 2>&1; then
  fail "purge ran without verified-backup confirmation"
fi
[[ ! -s "$test_log" ]] ||
  fail "unconfirmed purge reached remote transport"

: >"$test_log"
CONFIG_FILE="$config_file" \
PATH="$fake_bin:$PATH" \
TEST_TRANSPORT_LOG="$test_log" \
  "$client_under_test/purge.sh" >/dev/null
grep -Fq "'apt-get' 'purge' '-y' '@@PACKAGE_NAME@@'" \
  "$test_log" ||
  fail "purge did not invoke the exact package purge command"
grep -Fq 'Status-Abbrev' "$test_log" ||
  fail "purge did not verify final package state"
if grep -Eq "'rm'|'rmdir'|'shred'|'docker'" "$test_log"; then
  fail "purge attempted data or file cleanup"
fi

: >"$test_log"
CONFIG_FILE="$config_file" \
PATH="$fake_bin:$PATH" \
TEST_TRANSPORT_LOG="$test_log" \
  "$client_under_test/forward-localhost.sh" >/dev/null
grep -Fq '<127.0.0.1:18443:127.0.0.1:443>' "$test_log" ||
  fail "default HTTPS high-port loopback forward changed"
grep -Fq '<127.0.0.1:18080:127.0.0.1:80>' "$test_log" ||
  fail "default HTTP high-port loopback forward changed"

: >"$test_log"
CONFIG_FILE="$config_file" \
LOCAL_FORWARD_PORTS_OVERRIDE=19444:18444,19082:18082 \
PATH="$fake_bin:$PATH" \
TEST_TRANSPORT_LOG="$test_log" \
  "$client_under_test/forward-localhost.sh" >/dev/null
grep -Fq '<127.0.0.1:19444:127.0.0.1:18444>' "$test_log" ||
  fail "custom HTTPS public-port forward changed"
grep -Fq '<127.0.0.1:19082:127.0.0.1:18082>' "$test_log" ||
  fail "custom HTTP public-port forward changed"

if CONFIG_FILE="$config_file" \
    LOCAL_FORWARD_PORTS_OVERRIDE=443:443 \
    PATH="$fake_bin:$PATH" \
    TEST_TRANSPORT_LOG="$test_log" \
    "$client_under_test/forward-localhost.sh" >/dev/null 2>&1; then
  fail "privileged local tunnel port was accepted"
fi

package_script="$repository_root/build/scripts/package-production.sh"
[[ -x "$package_script" ]] ||
  fail "package-production.sh is missing or is not executable"
artifact_dir="$work_dir/dist"
mkdir -p "$artifact_dir"
MYSCOUTEE_VERSION=1.0.0 \
MYSCOUTEE_DIST_DIR="$artifact_dir" \
PACKAGE_IMAGES=false \
ALLOW_UNBUNDLED_IMAGES_FOR_TESTS=true \
BUILD_ARTIFACTS=false \
SOURCE_DATE_EPOCH=1700000000 \
  "$package_script" >/dev/null

client_archive="$artifact_dir/@@PACKAGE_NAME@@-client-tools_1.0.0.tar.gz"
[[ -s "$client_archive" ]] ||
  fail "standalone client-tools archive is missing"
[[ "$(stat -c '%a' "$client_archive")" == "644" ]] ||
  fail "standalone client-tools archive is not mode 0644"
reproducible_artifact_dir="$work_dir/reproducible-dist"
mkdir -p "$reproducible_artifact_dir"
MYSCOUTEE_VERSION=1.0.0 \
MYSCOUTEE_DIST_DIR="$reproducible_artifact_dir" \
PACKAGE_IMAGES=false \
ALLOW_UNBUNDLED_IMAGES_FOR_TESTS=true \
BUILD_ARTIFACTS=false \
SOURCE_DATE_EPOCH=1700000000 \
  "$package_script" >/dev/null
cmp -s \
  "$client_archive" \
  "$reproducible_artifact_dir/@@PACKAGE_NAME@@-client-tools_1.0.0.tar.gz" ||
  fail "client-tools archive is not reproducible"
package_path="$artifact_dir/@@PACKAGE_NAME@@_1.0.0_amd64.deb"
embedded_client_archive="$work_dir/embedded-client-tools.tar.gz"
dpkg-deb --fsys-tarfile "$package_path" |
  tar -xOf - \
    ./usr/share/@@PACKAGE_NAME@@/@@PACKAGE_NAME@@-client-tools_1.0.0.tar.gz \
    >"$embedded_client_archive" ||
  fail "Debian package omits the versioned client-tools archive"
cmp -s "$client_archive" "$embedded_client_archive" ||
  fail "Debian-embedded client-tools archive differs from standalone artifact"
package_members="$work_dir/package-members.txt"
dpkg-deb --fsys-tarfile "$package_path" | tar -tf - >"$package_members"
for forbidden_unpacked_member in \
  ./usr/share/@@PACKAGE_NAME@@/client-tools \
  ./usr/share/@@PACKAGE_NAME@@/install.sh \
  ./usr/share/@@PACKAGE_NAME@@/deployment.env.example \
  ./usr/share/@@PACKAGE_NAME@@/verify-deployment/run.mjs; do
  if grep -Fxq "$forbidden_unpacked_member" "$package_members"; then
    fail "Debian package contains unpacked client tool: $forbidden_unpacked_member"
  fi
done
archive_members="$work_dir/archive-members.txt"
tar -tzf "$client_archive" | sed 's|/$||' | sed '/^$/d' |
  LC_ALL=C sort -u >"$archive_members"
if grep -Eq '(^/|(^|/)\.\.(/|$))' "$archive_members"; then
  fail "standalone client-tools archive contains an unsafe path"
fi
for expected_member in \
  ./README.md \
  ./VERSION \
  ./deployment.env.example \
  ./forward-localhost.sh \
  ./install.env.example \
  ./install.sh \
  ./purge.sh \
  ./remote-transport.sh \
  ./verify-release.sh \
  ./verify-deployment/README.md \
  ./verify-deployment/run.mjs \
  ./verify-deployment/checks.mjs \
  ./verify-deployment/lib/assertions.mjs \
  ./verify-deployment/lib/http.mjs; do
  grep -Fxq "$expected_member" "$archive_members" ||
    fail "standalone client-tools archive omits $expected_member"
done
if grep -Eq '(^|/)(install|deployment)\.env$|(^|/)tls/' \
    "$archive_members"; then
  fail "local Operator provisioning inputs entered the client-tools archive"
fi
if grep -Fxq './.gitignore' "$archive_members"; then
  fail "client-only ignore metadata entered the release archive"
fi
if grep -E '\.env($|/)' "$archive_members" |
    grep -Ev '^\./(install|deployment)\.env\.example$' |
    grep -q .; then
  fail "an environment file other than the reviewed examples entered the archive"
fi
if grep -Ei '\.(pem|key|p8|p12|jks|db|db-wal|db-shm)$' \
    "$archive_members" | grep -q .; then
  fail "a credential or runtime-state filename entered the archive"
fi
archive_extract="$work_dir/archive-extract"
mkdir -p "$archive_extract"
tar -xzf "$client_archive" -C "$archive_extract"
if find "$archive_extract" -type l -print -quit | grep -q .; then
  fail "a symbolic link entered the archive"
fi
if LC_ALL=C grep -aERq -- \
    '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----' "$archive_extract"; then
  fail "a private-key marker entered the archive"
fi
if grep -Eq 'REMOTE_(PASSWORD|SUDO_PASSWORD)=[^[:space:]]+' \
    "$archive_extract/install.env.example"; then
  fail "configuration example contains a password"
fi
grep -Eq '^REGISTRY_SCOPE=$' "$archive_extract/deployment.env.example" ||
  fail "archived deployment example contains a permanent scope"
grep -Eq '^REGISTRY_PUBLIC_HOSTNAME=$' \
  "$archive_extract/deployment.env.example" ||
  fail "archived deployment example contains a public hostname"
[[ "$(tr -d '\r\n' <"$archive_extract/VERSION")" == "1.0.0" ]] ||
  fail "client-tools archive version changed"

debian_artifact="$artifact_dir/@@PACKAGE_NAME@@_1.0.0_amd64.deb"
[[ -s "$debian_artifact" ]] ||
  fail "test package is missing for signed release verification"
private_key="$work_dir/release-private.pem"
public_key="$work_dir/release-public.pem"
public_der="$work_dir/release-public.der"
openssl genpkey -algorithm ED25519 -out "$private_key" >/dev/null 2>&1
openssl pkey -in "$private_key" -pubout -out "$public_key" >/dev/null 2>&1
openssl pkey -pubin -in "$public_key" -outform DER -out "$public_der" \
  >/dev/null 2>&1
public_sha="$(sha256sum "$public_der" | awk '{print $1}')"
trusted_fingerprint="sha256:$public_sha"
signing_key_id="pkey_${public_sha:0:32}"

debian_size="$(stat -c '%s' "$debian_artifact")"
debian_sha="sha256:$(sha256sum "$debian_artifact" | awk '{print $1}')"
debian_message="$work_dir/debian.message"
printf '%s\n' \
  @@PACKAGE_DOMAIN@@ \
  1.0.0 \
  stable \
  "$debian_size" \
  "$debian_sha" \
  >"$debian_message"
openssl pkeyutl -sign -rawin -inkey "$private_key" \
  -in "$debian_message" -out "$work_dir/debian.signature"
debian_signature="$(base64 -w 0 "$work_dir/debian.signature")"

client_size="$(stat -c '%s' "$client_archive")"
client_sha="sha256:$(sha256sum "$client_archive" | awk '{print $1}')"
client_message="$work_dir/client.message"
printf '%s\n' \
  @@CLIENT_DOMAIN@@ \
  1.0.0 \
  stable \
  "$client_size" \
  "$client_sha" \
  >"$client_message"
openssl pkeyutl -sign -rawin -inkey "$private_key" \
  -in "$client_message" -out "$work_dir/client.signature"
client_signature="$(base64 -w 0 "$work_dir/client.signature")"

release_manifest="$work_dir/@@PACKAGE_NAME@@-release_1.0.0.json"
jq -n \
  --arg keyId "$signing_key_id" \
  --arg debSha "$debian_sha" \
  --arg debSignature "$debian_signature" \
  --arg clientSha "$client_sha" \
  --arg clientSignature "$client_signature" \
  --argjson debSize "$debian_size" \
  --argjson clientSize "$client_size" \
  '{
    schemaVersion: 1,
    version: "1.0.0",
    channel: "stable",
    signingKeyId: $keyId,
    artifacts: [
      {
        filename: "@@PACKAGE_NAME@@_1.0.0_amd64.deb",
        purpose: "debian-package",
        sizeBytes: $debSize,
        sha256: $debSha,
        signature: $debSignature
      },
      {
        filename: "@@PACKAGE_NAME@@-client-tools_1.0.0.tar.gz",
        purpose: "client-tools",
        sizeBytes: $clientSize,
        sha256: $clientSha,
        signature: $clientSignature
      }
    ]
  }' >"$release_manifest"

"$client_source/verify-release.sh" \
  "$debian_artifact" \
  "$release_manifest" \
  "$public_key" \
  "$trusted_fingerprint" >/dev/null
"$client_source/verify-release.sh" \
  "$client_archive" \
  "$release_manifest" \
  "$public_key" \
  "$trusted_fingerprint" >/dev/null
if "$client_source/verify-release.sh" \
    "$debian_artifact" \
    "$release_manifest" \
    "$public_key" \
    "sha256:$(printf '0%.0s' {1..64})" >/dev/null 2>&1; then
  fail "release verification accepted an untrusted public-key fingerprint"
fi

printf 'client-tools-test: passed\n'
