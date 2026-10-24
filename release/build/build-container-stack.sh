#!/usr/bin/env bash
# Build selected Docker contexts; language-specific build definitions stay data.
set -Eeuo pipefail
umask 077
repository_root="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}"
configuration="$repository_root/config/packaging/build-contexts.json"
version="${1:-${MYSCOUTEE_VERSION:-$(sed -n '1p' "$repository_root/config/packaging/VERSION")}}"
docker_bin="${DOCKER_BIN:-docker}"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo 'version must be a plain SemVer core' >&2; exit 1; }
command -v "$docker_bin" >/dev/null 2>&1 || { echo "Docker is unavailable: $docker_bin" >&2; exit 1; }
jq -e '
 def relative: type == "string" and test("^[A-Za-z0-9_./-]+$") and (startswith("/") | not) and (split("/") | all(. != ".." and . != "." and . != ""));
 .schemaVersion == 1 and .architecture == "amd64"
 and (.contexts | type == "array" and length > 0 and length <= 32)
 and ([.contexts[].name] | length == (unique | length))
 and all(.contexts[];
   (.name | type == "string" and test("^[a-z][a-z0-9-]+$"))
   and (.repository | type == "string" and test("^[a-z][a-z0-9-]+$"))
   and (.imageEnvironment | type == "string" and test("^[A-Z][A-Z0-9_]+$"))
   and (.inputs | type == "array" and length > 0 and length <= 64)
   and ([.inputs[].target] | length == (unique | length))
   and all(.inputs[]; (.source | relative) and (.target | relative)))
' "$configuration" >/dev/null || { echo 'Invalid Docker context configuration' >&2; exit 1; }
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/container-stack-build.XXXXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
while IFS= read -r context; do
 name="$(jq -r .name <<< "$context")"
 image_environment="$(jq -r .imageEnvironment <<< "$context")"
 reference="$(jq -r .repository <<< "$context"):${version}-prod"
 [[ -z "${!image_environment:-}" || "${!image_environment}" == "$reference" ]] || { echo "$image_environment must use the canonical version-derived tag" >&2; exit 1; }
 directory="$work_dir/$name"
 install -d "$directory"
 while IFS=$'\t' read -r source target; do
   source="$repository_root/$source"
   [[ -e "$source" && ! -L "$source" ]] || { echo 'Missing or unsafe context input' >&2; exit 1; }
   install -d "$(dirname "$directory/$target")"
   if [[ -d "$source" ]]; then cp -a "$source" "$directory/$target";
   else install -m 0644 "$source" "$directory/$target"; fi
 done < <(jq -r '.inputs[] | [.source,.target] | @tsv' <<< "$context")
 "$docker_bin" build --platform linux/amd64 --build-arg "MYSCOUTEE_VERSION=$version" --tag "$reference" "$directory"
done < <(jq -c '.contexts[]' "$configuration")
