#!/usr/bin/env bash
# Package-owned identity and managed-image inventory. Never read from an API
# request, mutable deployment configuration, or a downloaded candidate package.

release_project_load() {
  local directory="$1" expected_owner="$2" policy
  policy="${directory}/release-project.json"
  if [[ ! -e "$policy" && ! -L "$policy" ]]; then
    policy="${directory}/../../config/packaging/release-project.json"
  fi
  [[ -f "$policy" && ! -L "$policy" && "$(stat -c %u "$policy")" == "$expected_owner" ]] || return 1
  (( (8#$(stat -c %a "$policy") & 8#022) == 0 )) || return 1
  (( $(stat -c %s "$policy") <= 65536 )) || return 1
  jq -e '
    def name: type == "string" and test("^[a-z][a-z0-9-]{1,63}$");
    def version: type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-qa\\.[1-9][0-9]*)?$");
    type == "object" and (del(.clientTools, .hostTools) | keys | sort) == ["images","packageName","runtimeIdentity","schemaVersion"]
    and (.hostTools == null or (.hostTools | type == "object"
      and (.startupFallbackVersion | version)
      and (.migration.mediaManifest == null or (.migration.mediaManifest | type == "string"
        and test("^[a-zA-Z0-9_./-]+$") and (split("/") | all(. != ".."))))
      and (.tls.applicationUrlEnvironmentKeys | type == "array" and length > 0
        and all(.[]; type == "string" and test("^[A-Z][A-Z0-9_]*$")))
      and (.tls.localOrigins | type == "array" and all(.[]; type == "string" and test("^https?://[^,[:space:]]+$")))
      and (.registry == null or (.registry | type == "object"
        and all(.[]; type == "string" and startswith("/") and (split("/") | all(. != "..")))))))
    and .schemaVersion == 1 and (.packageName | name)
    and (.runtimeIdentity | type == "object" and (keys | sort) == ["gid","uid"]
      and all(.[]; type == "number" and floor == . and . >= 10000 and . <= 60000))
    and (.images | type == "array" and length > 0 and length <= 32)
    and ([.images[].service] | length == (unique | length))
    and ([.images[].environment] | length == (unique | length))
    and all(.images[];
      type == "object" and (keys | sort) == ["container","environment","repository","service","sinceVersion","tagSuffix"]
      and (.service | name) and (.repository | name)
      and (.container == null or (.container | name))
      and (.environment | type == "string" and test("^[A-Z][A-Z0-9_]{1,63}$"))
      and (.tagSuffix == "base" or .tagSuffix == "prod")
      and (.sinceVersion | version))
  ' "$policy" >/dev/null || return 1
  RELEASE_PROJECT_POLICY="$policy"
  RELEASE_PROJECT_NAME="$(jq -r '.packageName' "$policy")"
  RELEASE_PROJECT_ROOT="/opt/${RELEASE_PROJECT_NAME}"
  RELEASE_PROJECT_UID="$(jq -r '.runtimeIdentity.uid' "$policy")"
  RELEASE_PROJECT_GID="$(jq -r '.runtimeIdentity.gid' "$policy")"
}

release_project_images() {
  local version="$1" row since
  local -a rows=()
  [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-qa\.[1-9][0-9]*)?$ ]] || return 1
  mapfile -t rows < <(jq -c '.images[]' "$RELEASE_PROJECT_POLICY")
  for row in "${rows[@]}"; do
    since="$(jq -r '.sinceVersion' <<< "$row")"
    if dpkg --compare-versions "${version/-/\~}" ge "${since/-/\~}"; then
      jq -c --arg version "$version" '. + {reference: (.repository + ":" + $version + "-" + .tagSuffix)}' <<< "$row"
    fi
  done | jq -s '.'
}

release_project_validate_manifest() {
  local manifest="$1" version="$2" expected
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
  (( $(stat -c %s "$manifest") <= 65536 )) || return 1
  expected="$(release_project_images "$version")" || return 1
  jq -e --arg version "$version" --argjson expected "$expected" '
    type == "object"
    and (keys | sort) == ["bundled","images","releaseVersion","schemaVersion"]
    and .schemaVersion == 1 and .releaseVersion == $version and .bundled == true
    and (.images | type == "array" and length == ($expected | length))
    and (([.images[] | {service,container,reference}] | sort_by(.service))
      == ([$expected[] | {service,container,reference}] | sort_by(.service)))
    and all(.images[];
      type == "object"
      and (keys | sort) == ["container","contentFingerprint","imageId","reference","service"]
      and (.imageId | type == "string" and test("^sha256:[0-9a-f]{64}$"))
      and (.contentFingerprint | type == "string" and test("^sha256:[0-9a-f]{64}$")))
  ' "$manifest" >/dev/null
}

# Build commands may use an explicit local image override. A release package
# must use only the exact version-derived references in its installed policy.
release_project_export_images() {
  local version="$1" strict="${2:-false}" inventory name reference current
  inventory="$(release_project_images "$version")" || return 1
  while IFS=$'\t' read -r name reference; do
    current="${!name-}"
    if [[ "$strict" == true && -n "$current" && "$current" != "$reference" ]]; then
      echo "Release packages require the canonical version-derived image for ${name}." >&2
      return 1
    fi
    export "${name}=${current:-$reference}"
  done < <(jq -r '.[] | [.environment,.reference] | @tsv' <<< "$inventory")
}
