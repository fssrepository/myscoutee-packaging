#!/usr/bin/env bash
# QA-only self-signed certificate renewal, run inside the selected VMware guest.
# Keeps the existing private key; does not touch Registry signing identity/data.
set -euo pipefail
[[ "${1:-}" == --config && $# == 3 ]] || { echo 'Usage: renew-qa-registry-certificate.sh --config RELEASE_PROJECT_JSON GUEST_IPV4' >&2; exit 2; }
config="$2"
host="$3"
config_directory="$(cd -- "$(dirname -- "$config")" && pwd)"
project_config="$config_directory/$(jq -er '.releaseProject' "$config")"
package_name="$(jq -er '.packageName' "$project_config")"
nginx_container="$(jq -er '.registryNginxContainer' "$config")"
[[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
version="$(dpkg-query -W -f='${Version}' "$package_name")"
[[ "$version" == *'~qa.'* ]] || { echo 'QA guest required' >&2; exit 1; }
dir="$(jq -er '.registryTlsDirectory' "$config")"
cert="$dir/fullchain.pem"
key="$dir/privkey.pem"
openssl x509 -in "$cert" -noout -checkip "$host" >/dev/null
subject="$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253)"
issuer="$(openssl x509 -in "$cert" -noout -issuer -nameopt RFC2253)"
[[ "${subject#subject=}" == "${issuer#issuer=}" ]] || { echo 'Only QA self-signed certificates allowed' >&2; exit 1; }
if openssl x509 -in "$cert" -noout -checkend 604800 >/dev/null; then
  echo 'Certificate still valid for at least seven days; no change'; exit 0
fi
umask 077
work="$(mktemp -d "$dir/.renew.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
openssl req -new -x509 -key "$key" -out "$work/fullchain.pem" -days 90 \
  -subj "/CN=$host" -addext "subjectAltName=IP:$host,DNS:$host" >/dev/null 2>&1
openssl verify -CAfile "$work/fullchain.pem" -verify_ip "$host" "$work/fullchain.pem" >/dev/null
cp "$cert" "$work/previous.pem"
# Keep the bind-mounted inode; nginx continues serving old context until reload.
cat "$work/fullchain.pem" > "$cert"
if ! docker exec "$nginx_container" nginx -t; then
  cat "$work/previous.pem" > "$cert"
  exit 1
fi
docker exec "$nginx_container" nginx -s reload
openssl x509 -in "$cert" -noout -dates -fingerprint -sha256
