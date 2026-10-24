#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  printf 'debian-removal-contract-test: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repository_root="$(cd -- "$script_dir/../../.." && pwd -P)"
postrm="$repository_root/build/debian/postrm"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/registry-removal-test.XXXXXXXX")"
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT
fake_bin="$work_dir/bin"
command_log="$work_dir/commands.log"
env_file="$work_dir/registry.env"
mkdir -p "$fake_bin"
: >"$command_log"

cat >"$fake_bin/systemctl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'systemctl\t%s\n' "$*" >>"${REMOVAL_COMMAND_LOG:?}"
SCRIPT
cat >"$fake_bin/docker" <<'SCRIPT'
#!/usr/bin/env bash
printf 'docker\t%s\n' "$*" >>"${REMOVAL_COMMAND_LOG:?}"
SCRIPT
cat >"$fake_bin/rm" <<'SCRIPT'
#!/usr/bin/env bash
printf 'rm\t%s\n' "$*" >>"${REMOVAL_COMMAND_LOG:?}"
SCRIPT
chmod 0755 "$fake_bin"/*
printf '%s\n' \
  'REGISTRY_PRODUCTION_IMAGE=@@PACKAGE_NAME@@:1.0.0-prod' \
  'REGISTRY_NGINX_PRODUCTION_IMAGE=@@NGINX_IMAGE@@:1.0.0-prod' \
  >"$env_file"

run_postrm() {
  PATH="$fake_bin:/usr/bin:/bin" \
  REMOVAL_COMMAND_LOG="$command_log" \
  MYSCOUTEE_REGISTRY_POSTRM_ENV_FILE="$env_file" \
    bash "$postrm" "$1" >/dev/null
}

run_postrm remove
if grep -Eq '^(rm|docker)\t' "$command_log"; then
  fail "normal removal deleted state or managed images"
fi

: >"$command_log"
run_postrm purge
grep -Fqx $'docker\timage rm -f @@PACKAGE_NAME@@:1.0.0-prod' \
  "$command_log" || fail "purge did not remove the configured Registry image"
grep -Fqx \
  $'docker\timage rm -f @@NGINX_IMAGE@@:1.0.0-prod' \
  "$command_log" || fail "purge did not remove the configured Nginx image"
for path in \
  /etc/@@PACKAGE_NAME@@ \
  /var/lib/@@PACKAGE_NAME@@ \
  /opt/@@PACKAGE_NAME@@; do
  grep -Fqx $'rm\t-rf '"$path" "$command_log" ||
    fail "purge did not remove $path"
done
if grep -Eq 'docker\timage rm.*(:dev|-dev|:latest)' "$command_log"; then
  fail "purge removed a development or unversioned image"
fi

for abort_action in abort-install abort-upgrade; do
  run_postrm "$abort_action"
done
if bash "$postrm" unsupported >/dev/null 2>&1; then
  fail "postrm accepted an unsupported action"
fi

printf 'Debian removal contract: PASS\n'
