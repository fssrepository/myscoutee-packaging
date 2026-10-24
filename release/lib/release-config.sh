#!/usr/bin/env bash
# Source-checkout release data. Values remain data; never evaluate JSON as shell.
release_config_load() {
  local project="$1" source policy
  source="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  policy="${project}/config/packaging/release/settings.json"
  RELEASE_SETTINGS="$(jq -es '
    if all(.[]; type == "object" and .schemaVersion == 1)
    then reduce .[] as $item ({}; . * $item)
    else error("Invalid release settings") end
  ' "${source}/defaults.json" "$policy")" || return 1
  local -a debian_inputs=("${source}/../../debian/defaults.json")
  if [[ -f "${project}/config/packaging/debian/lifecycle.json" ]]; then
    debian_inputs+=("${project}/config/packaging/debian/lifecycle.json")
  fi
  RELEASE_DEBIAN_SETTINGS="$(jq -es '.[0].lifecycle * (.[1] // {})' "${debian_inputs[@]}")" || return 1
}

release_config_value() {
  jq -er "$1" <<< "$RELEASE_SETTINGS"
}

release_official_image() {
  jq -er --arg environment "$1" '.requiredImages[] | select(.environment == $environment) | .default' \
    <<< "$RELEASE_DEBIAN_SETTINGS"
}
