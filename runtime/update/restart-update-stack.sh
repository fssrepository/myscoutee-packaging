#!/usr/bin/env bash
set -euo pipefail

# Keep the current HTTPS ingress and the host status reader alive while replacing
# the application. Switch the nginx image last; the browser retries that brief gap.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/release-project.sh"
release_project_load "${SCRIPT_DIR}" "$(stat -c %u "${BASH_SOURCE[0]}")" || {
  echo 'The package-owned release project policy is missing or unsafe.' >&2; exit 1;
}
COMPOSE="${MYSCOUTEE_COMPOSE_SCRIPT:-${SCRIPT_DIR}/myscoutee-compose.sh}"
TIMEOUT="${MYSCOUTEE_UPDATE_HEALTH_TIMEOUT_SECONDS:-300}"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ && "$TIMEOUT" -le 3600 ]] || exit 1
systemctl is-active --quiet "${RELEASE_PROJECT_NAME}.service"
systemctl is-active --quiet "${RELEASE_PROJECT_NAME}-update-status.socket"

# The worker inherited these values before apt installed the new package.
# postinst updates the installed .env; let Compose read that current file for
# both upgrade and rollback rather than overriding it with the worker snapshot.
unset MYSCOUTEE_VERSION
while IFS= read -r name; do unset "$name"; done < <(jq -r '.images[].environment' "$RELEASE_PROJECT_POLICY")
configuration="$("$COMPOSE" config --no-env-resolution --format json)"
backend_container="$(jq -er '.services.profilemanagement.container_name' <<< "$configuration")"
support_services_json="$(jq -ce '[.services | keys[] | select(. != "nginx" and . != "profilemanagement")] | select(length>0)' <<< "$configuration")"
mapfile -t support_services < <(jq -r '.[]' <<< "$support_services_json")

"$COMPOSE" stop profilemanagement
printf '[myscoutee-update-phase] PREPARING_DATA\n'
"${SCRIPT_DIR}/reset-demo-state.sh"
"${SCRIPT_DIR}/sync-i18n-seeds.sh" --prepare-only
"${SCRIPT_DIR}/migrate-production-data.sh"
printf '[myscoutee-update-phase] STARTING_SERVICES\n'
"$COMPOSE" up -d --no-deps --wait --wait-timeout "$TIMEOUT" "${support_services[@]}"
"$COMPOSE" up -d --no-deps profilemanagement
printf '[myscoutee-update-phase] WAITING_FOR_HEALTH\n'
deadline=$((SECONDS + TIMEOUT))
while (( SECONDS < deadline )); do
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$backend_container")"
  if [[ "$health" == healthy ]]; then
    printf '[myscoutee-update-phase] SWITCHING_INGRESS\n'
    "$COMPOSE" up -d --no-deps nginx
    exit 0
  fi
  [[ "$health" != unhealthy ]] || exit 1
  sleep 2
done
echo "Application health deadline exceeded; retained HTTPS progress remains available." >&2
exit 1
