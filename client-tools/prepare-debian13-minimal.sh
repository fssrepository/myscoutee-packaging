#!/usr/bin/env bash
set -euo pipefail

# Standalone host preparation, run BEFORE apt install ./myscoutee_*.deb.
# Distributed with client tools; explicitly copied to and run on the target.
# Never invoked by the application installer or its package hooks.
# Docker installation follows https://docs.docker.com/engine/install/debian/.

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi
. /etc/os-release
if [[ "${ID:-}" != "debian" || "${VERSION_ID:-}" != "13" ]]; then
  echo "This host preparation script supports Debian 13 only." >&2
  exit 1
fi
if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
  echo "The current MyScoutee release requires an amd64 host." >&2
  exit 1
fi

installed() {
  [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" == "installed" ]]
}

# Never remove an existing container runtime or its data implicitly.
for package in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do
  if installed "${package}"; then
    echo "Installed package ${package} conflicts with Docker CE; migrate the existing runtime explicitly first." >&2
    exit 1
  fi
done

packages=()
for package in bash coreutils ca-certificates curl jq openssl python3 systemd tar util-linux \
  docker-ce docker-ce-cli containerd.io docker-compose-plugin; do
  if ! installed "${package}"; then
    packages+=("${package}")
  fi
done

if [[ "${#packages[@]}" -gt 0 ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl

  # Keep an existing operator-provided Docker source intact.
  if [[ ! -e /etc/apt/sources.list.d/docker.sources && ! -e /etc/apt/sources.list.d/docker.list ]]; then
    install -d -m 0755 /etc/apt/keyrings
    docker_key_tmp="$(mktemp)"
    trap 'rm -f -- "${docker_key_tmp}"' EXIT
    curl --fail --silent --show-error --location \
      --connect-timeout 15 --max-time 120 \
      https://download.docker.com/linux/debian/gpg -o "${docker_key_tmp}"
    install -m 0644 "${docker_key_tmp}" /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/docker.sources <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    chmod 0644 /etc/apt/sources.list.d/docker.sources
  fi

  apt-get update
  apt-get install -y --no-install-recommends "${packages[@]}"
fi

systemctl enable --now docker
docker version --format 'Docker Engine: {{.Server.Version}}'
docker compose version
docker info >/dev/null
echo "Debian 13 prerequisites ready. Next: apt install ./myscoutee_1.0.0_amd64.deb"
