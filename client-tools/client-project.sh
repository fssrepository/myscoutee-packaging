#!/usr/bin/env bash
# Shared client configuration and source/archive policy binding.

client_project_setup() {
  local directory="$1"
  if [[ -f "$directory/release-project.sh" ]]; then
    CLIENT_PROJECT_POLICY_DIRECTORY="$directory"
    source "$directory/release-project.sh"
    CLIENT_PROJECT_CONFIG_DIRECTORY="$directory"
  else
    [[ -n "${MYSCOUTEE_PACKAGING_PROJECT_ROOT:-}" ]] || return 1
    CLIENT_PROJECT_POLICY_DIRECTORY="$MYSCOUTEE_PACKAGING_PROJECT_ROOT/config/packaging"
    source "$(dirname -- "${BASH_SOURCE[0]}")/../release/lib/release-project.sh"
    CLIENT_PROJECT_CONFIG_DIRECTORY="$MYSCOUTEE_PACKAGING_PROJECT_ROOT/config/packaging/client-tools"
  fi
}

# Client-only selections extend the same trusted policy; they do not add images
# to the release inventory or change the package/update manifest schema.
release_project_client_load() {
  release_project_load "$@" || return 1
  jq -e '
    def name: type == "string" and test("^[a-z][a-z0-9-]{1,63}$");
    def environment: type == "string" and test("^[A-Z][A-Z0-9_]{1,63}$");
    def relative_path:
      type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$")
      and (split("/") | all(. != "" and . != "." and . != ".."));
    def absolute_path: type == "string" and startswith("/") and (.[1:] | relative_path);
    .images as $images | .clientTools |
    type == "object"
    and (keys | sort) == ["composeFiles","installationPendingFile","serverDirectory","services","stateDirectory"]
    and (.serverDirectory | absolute_path) and (.stateDirectory | absolute_path)
    and (.installationPendingFile | relative_path)
    and (.composeFiles | type == "array" and length > 0 and length <= 8
      and length == (unique | length) and all(.[]; relative_path))
    and (.services | type == "array" and length > 0 and length <= 32)
    and ([.services[].name] | length == (unique | length))
    and ([.services[] | select(has("frontendVersionFile"))] | length <= 1)
    and all(.services[];
      . as $selection |
      type == "object" and (.name | name)
      and ((keys - ["allowStopped","container","environment","frontendVersionFile","imageService","labelService","name","sameUpstream","stateDirectory"]) | length == 0)
      and (if has("imageService") then
        (.imageService | name)
        and (has("container") or has("environment") or has("labelService") | not)
        and any($images[]; .service == $selection.imageService and .container != null)
      else
        (.container | name) and (.environment | environment) and (.labelService | name)
      end)
      and (if has("stateDirectory") then (.stateDirectory | relative_path) else true end)
      and (if has("frontendVersionFile") then (.frontendVersionFile | absolute_path) else true end)
      and (if has("allowStopped") then (.allowStopped | type == "boolean") else true end)
      and (if has("sameUpstream") then (.sameUpstream | type == "boolean") else true end))
  ' "$RELEASE_PROJECT_POLICY" >/dev/null
}

release_project_client_service() {
  local name="$1"
  jq -ce --arg name "$name" '
    . as $project | .clientTools.services[] | select(.name == $name) | . as $selection |
    (if has("imageService") then
      $project.images[] | select(.service == $selection.imageService) |
      {container, environment, labelService: .service}
    else {container, environment, labelService} end) + $selection
  ' "$RELEASE_PROJECT_POLICY"
}

