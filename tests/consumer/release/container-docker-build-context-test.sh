#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  printf 'docker-build-context-test: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repository_root="$(cd -- "$script_dir/../../.." && pwd -P)"
root_dockerfile="$repository_root/Dockerfile"
root_ignore="$repository_root/Dockerfile.dockerignore"
production_dockerfile="$repository_root/config/packaging/templates/registry.Dockerfile"
build_script="$repository_root/build/scripts/build-production.sh"

case_config="$repository_root/config/packaging/tests/docker-context.json"
while IFS= read -r copy_contract; do
  grep -Fq "$copy_contract" "$root_dockerfile" ||
    fail "development Dockerfile lost restricted input: $copy_contract"
  grep -Fq "$copy_contract" "$production_dockerfile" ||
    fail "production Dockerfile lost restricted input: $copy_contract"
done < <(jq -r '.copyContracts[]' "$case_config")
if grep -Eq '^COPY[[:space:]]+\.[[:space:]]+\.[[:space:]]*$' \
  "$root_dockerfile" "$production_dockerfile"; then
  fail "a Registry Dockerfile copies the entire repository"
fi
grep -Fxq '**' "$root_ignore" ||
  fail "development Docker context is not deny-by-default"
jq -e --slurpfile contract "$case_config" '
  .contexts[] | select(.name == "registry") | .inputs as $inputs |
  all($inputs[]; .source != "." and .target != ".") and
  all($contract[0].copyContracts[];
    sub("^COPY "; "") | split(" ") | .[:-1] |
    all(.[]; rtrimstr("/") as $source |
      any($inputs[]; .source == $source and .target == $source)))' \
  "$repository_root/config/packaging/build-contexts.json" >/dev/null ||
  fail "production build lost its restricted source context"
grep -Fq \
  "$(jq -r .versionSymbol "$case_config")" \
  "$production_dockerfile" ||
  fail "production build does not embed the release version"

printf 'Docker build context contract: PASS\n'
