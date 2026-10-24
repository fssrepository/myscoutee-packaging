#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  printf 'package-contract-test: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repository_root="$(cd -- "$script_dir/../../.." && pwd -P)"
package_script="$repository_root/build/scripts/package-production.sh"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/registry-package-test.XXXXXXXX")"
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT
fake_bin="$work_dir/bin"
layer_root="$work_dir/layer"
dist_dir="$work_dir/dist"
extract_root="$work_dir/extract"
control_root="$work_dir/control"
mkdir -p "$fake_bin" "$layer_root" "$dist_dir" "$extract_root" "$control_root"
printf '%s\n' 'production image fixture' >"$layer_root/layer.txt"

cat >"$fake_bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail

id_for() {
  case "$1" in
    @@PACKAGE_NAME@@:9.8.7-prod)
      printf 'sha256:%064d' 1
      ;;
    @@NGINX_IMAGE@@:9.8.7-prod)
      printf 'sha256:%064d' 2
      ;;
    *)
      exit 1
      ;;
  esac
}

[[ "${1:-}" == "image" ]] || exit 1
case "${2:-}" in
  inspect)
    shift 2
    if [[ "${1:-}" == "--format" ]]; then
      format="$2"
      reference="$3"
      case "$format" in
        '{{.Id}}')
          id_for "$reference"
          ;;
        '{{.Os}}/{{.Architecture}}')
          printf 'linux/amd64'
          ;;
        '{{json .Config}}')
          printf '%s' '{"User":"65532:65532","Env":[]}'
          ;;
        *)
          exit 1
          ;;
      esac
    elif [[ "${1:-}" == "--" ]]; then
      reference="$2"
      image_id="$(id_for "$reference")"
      jq -n --arg imageId "$image_id" --arg reference "$reference" '
        [{
          Id: $imageId,
          Architecture: "amd64",
          Os: "linux",
          Config: {
            User: "65532:65532",
            Env: [],
            Entrypoint: ["/entrypoint"],
            Cmd: [],
            WorkingDir: "/",
            Labels: {release: $reference},
            ExposedPorts: {"8080/tcp": {}},
            Volumes: {"/data": {}},
            Healthcheck: null
          },
          RootFS: {
            Type: "layers",
            Layers: [$imageId]
          }
        }]
      '
    else
      exit 1
    fi
    ;;
  history)
    exit 0
    ;;
  save)
    [[ "${3:-}" == "--output" ]] || exit 1
    tar -C "${FAKE_DOCKER_LAYER_ROOT:?}" -cf "$4" .
    ;;
  *)
    exit 1
    ;;
esac
FAKE_DOCKER
chmod 0755 "$fake_bin/docker"

PATH="$fake_bin:$PATH" \
FAKE_DOCKER_LAYER_ROOT="$layer_root" \
DOCKER_BIN="$fake_bin/docker" \
MYSCOUTEE_REGISTRY_DIST_DIR="$dist_dir" \
BUILD_IMAGES=false \
SOURCE_DATE_EPOCH=0 \
  "$package_script" 9.8.7 >/dev/null

artifact="$dist_dir/@@PACKAGE_NAME@@_9.8.7_amd64.deb"
[[ -f "$artifact" ]] || fail "expected Debian artifact was not created"
[[ "$(stat -c '%a' "$artifact")" == "644" ]] ||
  fail "Debian artifact mode is not 0644"
dpkg-deb --extract "$artifact" "$extract_root"
dpkg-deb --control "$artifact" "$control_root"
control="$(dpkg-deb --field "$artifact")"
grep -qx 'Package: @@PACKAGE_NAME@@' <<<"$control" ||
  fail "package name is invalid"
grep -qx 'Version: 9.8.7' <<<"$control" ||
  fail "package version is invalid"
grep -qx 'Architecture: amd64' <<<"$control" ||
  fail "package architecture is invalid"
grep -Eqi 'docker.*compose|docker\.io|docker-ce' <<<"$control" ||
  fail "Docker runtime dependencies are absent"

compose="$extract_root/opt/@@PACKAGE_NAME@@/compose.yaml"
[[ "$(grep -c 'pull_policy: never' "$compose")" == "2" ]] ||
  fail "both production services must forbid pulls"
if grep -Eq '^[[:space:]]*build:|/workspace|hot.?reload|-[[:space:]]+\.[/:]' \
    "$compose"; then
  fail "production Compose contains a build or development mount"
fi
grep -Fq 'REGISTRY_PRODUCTION_IMAGE' "$compose" ||
  fail "Registry image is not environment-selected"
grep -Fq 'REGISTRY_NGINX_PRODUCTION_IMAGE' "$compose" ||
  fail "Nginx image is not environment-selected"
registry_compose_block="$(
  sed -n '/^  registry:/,/^  nginx:/p' "$compose"
)"
if grep -Eq '^[[:space:]]+ports:' <<<"$registry_compose_block"; then
  fail "production Compose publishes the internal Registry backend"
fi
grep -Eq '^[[:space:]]+ports:' \
  <(sed -n '/^  nginx:/,/^networks:/p' "$compose") ||
  fail "production Nginx has no public port contract"

manifest="$extract_root/opt/@@PACKAGE_NAME@@/packaging/IMAGE-MANIFEST.json"
packaged_client_archive="$extract_root/usr/share/@@PACKAGE_NAME@@/@@PACKAGE_NAME@@-client-tools_9.8.7.tar.gz"
standalone_client_archive="$dist_dir/@@PACKAGE_NAME@@-client-tools_9.8.7.tar.gz"
jq -e '
  .schemaVersion == 1
  and .releaseVersion == "9.8.7"
  and .bundled == true
  and (.images | length == 2)
  and ([.images[].service] | sort == ["nginx", "registry"])
  and all(.images[];
    (.contentFingerprint | test("^sha256:[0-9a-f]{64}$"))
    and (.archiveSha256 | test("^sha256:[0-9a-f]{64}$")))
' "$manifest" >/dev/null ||
  fail "portable two-image manifest is invalid"
for readable_metadata in \
  "$extract_root/opt/@@PACKAGE_NAME@@/packaging/VERSION" \
  "$manifest" \
  "$packaged_client_archive"; do
  [[ "$(stat -c '%a' "$readable_metadata")" == "644" ]] ||
    fail "non-secret release metadata is not mode 0644: $readable_metadata"
done
[[ "$(find "$extract_root/opt/@@PACKAGE_NAME@@/images" \
  -type f -name '*.tar' | wc -l)" == "2" ]] ||
  fail "package does not contain exactly two image archives"

for required in \
  opt/@@PACKAGE_NAME@@/packaging/scripts/qualify-deployment.sh \
  opt/@@PACKAGE_NAME@@/packaging/scripts/image-content-fingerprint.sh \
  lib/systemd/system/@@PACKAGE_NAME@@.service \
  usr/share/@@PACKAGE_NAME@@/@@PACKAGE_NAME@@-client-tools_9.8.7.tar.gz; do
  [[ -e "$extract_root/$required" ]] ||
    fail "package payload is missing $required"
done
[[ "$(find "$extract_root/usr/share/@@PACKAGE_NAME@@" \
  -mindepth 1 -maxdepth 1 -type f | wc -l)" == "1" ]] ||
  fail "Debian package contains unpacked or additional client-tools files"
[[ "$(find "$extract_root/usr/share/@@PACKAGE_NAME@@" \
  -mindepth 1 -type d | wc -l)" == "0" ]] ||
  fail "Debian package contains an unpacked client-tools directory"
cmp -s "$packaged_client_archive" "$standalone_client_archive" ||
  fail "Debian-embedded and standalone client-tools archives are not byte-identical"
embedded_client_root="$work_dir/embedded-client-tools"
mkdir -p "$embedded_client_root"
tar -xzf "$packaged_client_archive" -C "$embedded_client_root"
grep -qx 'MYSCOUTEE_REGISTRY_VERSION=9.8.7' \
  "$embedded_client_root/deployment.env.example" ||
  fail "embedded deployment example version does not match the package"
for unpacked_client_path in \
  install.sh \
  deployment.env.example \
  verify-deployment/run.mjs; do
  [[ ! -e "$extract_root/usr/share/@@PACKAGE_NAME@@/$unpacked_client_path" ]] ||
    fail "unpacked client tool entered the Debian payload: $unpacked_client_path"
done
qualifier="$extract_root/opt/@@PACKAGE_NAME@@/packaging/scripts/qualify-deployment.sh"
for qualification_contract in \
  '/versionz' \
  'service == "@@PACKAGE_NAME@@"' \
  'version == $expectedVersion' \
  'protocol_version == $health[0].protocol_version' \
  '--cacert "$tls_certificate_path"' \
  '--connect-to "$connect_target"' \
  'contentFingerprint' \
  'restart-and-check'; do
  grep -Fq -- "$qualification_contract" "$qualifier" ||
    fail "host qualification contract is missing: $qualification_contract"
done
if grep -q 'REGISTRY_LOOPBACK_PORT' "$qualifier"; then
  fail "host qualification depends on a published Registry backend port"
fi
if grep -Eq 'cat[[:space:]]+.*(health|identity|version).*json' "$qualifier"; then
  fail "host qualification can print a fetched response body"
fi
grep -Fq -- \
  '-X github.com/fssrepository/@@PACKAGE_NAME@@/internal/buildinfo.Version=${MYSCOUTEE_VERSION}' \
  "$repository_root/config/packaging/templates/registry.Dockerfile" ||
  fail "production Registry image does not embed the release version"
if sed '/^cat <<MESSAGE/,$d' "$control_root/postinst" |
  grep -Eq \
    '(^|[;&])[[:space:]]*(node|[^[:space:]]*verify-deployment)|systemctl[[:space:]]+(start|restart)[[:space:]]+@@PACKAGE_NAME@@'; then
  fail "postinst starts or externally verifies the deployment"
fi

if find "$extract_root" -type f \
  \( -name '*.pem' -o -name '*.key' -o -name '*.db' \
    -o -name '*.db-wal' -o -name '*.db-shm' \) \
  -print -quit | grep -q .; then
  fail "private key or runtime state entered the package"
fi
if rg -n -i '\bedge\b|\boffline\b|\bcompatibility\b|\blegacy\b' \
    "$repository_root/guides/development/reference/packaging.md" \
    "$repository_root/config/packaging/compose" \
    "$repository_root/build/debian" \
    "$repository_root/build/scripts" \
    "$repository_root/build/systemd" \
    "$repository_root/config/packaging/templates" >/dev/null; then
  fail "superseded release vocabulary remains in the packaging contract"
fi

printf 'Production package contract: PASS\n'
