#!/usr/bin/env bash
# Compatibility shortcut for the explicitly scoped frontend update.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
action="${1:---help}"
if [[ "$action" == --help || "$action" == -h ]]; then
  exec bash "$script_dir/install-temporary-image.sh" --help
fi
shift
source "$script_dir/client-project.sh"
client_project_setup "$script_dir" || { echo 'Select a project with the packaging CLI.' >&2; exit 1; }
policy_directory="$CLIENT_PROJECT_POLICY_DIRECTORY"
release_project_client_load "$policy_directory" "$(stat -c %u "${BASH_SOURCE[0]}")" || { echo 'Invalid client project policy.' >&2; exit 1; }
frontend_service="$(jq -er '.clientTools.services[] | select(has("frontendVersionFile")) | .name' "$RELEASE_PROJECT_POLICY")"
exec bash "$script_dir/install-temporary-image.sh" "$action" "$frontend_service" "$@"
