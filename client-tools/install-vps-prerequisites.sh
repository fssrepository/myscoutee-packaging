#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root, for example: sudo $0" >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This installer currently supports Debian/Ubuntu apt-based systems." >&2
  exit 1
fi

packages=()
need_apt_update=false

add_package_if_command_missing() {
  local command_name="$1"
  local package_name="$2"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    packages+=("${package_name}")
    need_apt_update=true
  fi
}

package_available() {
  apt-cache show "$1" >/dev/null 2>&1
}

add_first_available_package() {
  local description="$1"
  shift

  local package_name
  for package_name in "$@"; do
    if package_available "${package_name}"; then
      packages+=("${package_name}")
      return 0
    fi
  done

  echo "No apt package found for ${description}. Install it manually, then rerun this script." >&2
  exit 1
}

add_package_if_command_missing curl curl
add_package_if_command_missing jq jq
add_package_if_command_missing gpg gnupg
add_package_if_command_missing openssl openssl
add_package_if_command_missing ufw ufw
add_package_if_command_missing ncdu ncdu
add_package_if_command_missing iotop iotop
add_package_if_command_missing redis-cli redis-tools

if ! command -v docker >/dev/null 2>&1; then
  packages+=(docker.io)
  need_apt_update=true
fi

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  need_apt_update=true
fi

if [[ "${need_apt_update}" == "true" ]]; then
  apt-get update
fi

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  add_first_available_package "Docker Compose v2 plugin" docker-compose-plugin docker-compose-v2
fi

if [[ "${#packages[@]}" -gt 0 ]]; then
  apt-get install -y --no-install-recommends "${packages[@]}"
fi

if ! command -v mongosh >/dev/null 2>&1; then
  if apt-cache show mongodb-mongosh >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends mongodb-mongosh
  else
    echo "mongosh is still missing. Install MongoDB Shell from the MongoDB package repository if host-side Mongo inspection is needed." >&2
  fi
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now docker
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is still missing after prerequisite installation." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 is still missing after prerequisite installation." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed, but the Docker daemon is not reachable." >&2
  exit 1
fi

echo "VPS prerequisite check complete."
