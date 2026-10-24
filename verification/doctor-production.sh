#!/usr/bin/env bash
set -euo pipefail

check_command() {
  local name="$1"
  if command -v "${name}" >/dev/null 2>&1; then
    printf "ok   %s\n" "${name}"
  else
    printf "miss %s\n" "${name}"
  fi
}

check_command docker
docker compose version >/dev/null 2>&1 && printf "ok   docker compose\n" || printf "miss docker compose\n"
check_command curl
check_command jq
check_command gpg
check_command ufw
check_command ncdu
check_command iotop
check_command redis-cli
check_command mongosh
