#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select the project with the packaging CLI.}"
NGINX_ROOT="${REPO_ROOT}/server/docker"
BASE_IMAGE="${NGINX_TEST_BASE_IMAGE:-$(jq -er .baseImage "${REPO_ROOT}/config/packaging/tests/nginx-transport.json")}"
TEST_ROOT="$(mktemp -d)"
RUNNING_CONTAINERS=()

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

cleanup() {
  local container

  for container in "${RUNNING_CONTAINERS[@]}"; do
    docker rm -f "${container}" >/dev/null 2>&1 || true
  done
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

for command_name in curl docker openssl; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "${command_name} is required"
done
docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1 \
  || fail "local Nginx base image is missing: ${BASE_IMAGE}"

DOCKERFILE="${NGINX_ROOT}/images/nginx/prod/Dockerfile"
SPRING_TEMPLATE="${REPO_ROOT}/config/nginx/http/spring.conf"
PROD_HTTP_POLICY="${REPO_ROOT}/config/nginx/http/http-transport-policy.prod.conf"
PROD_HTTPS_POLICY="${REPO_ROOT}/config/nginx/http/https-response-policy.prod.conf"
DEV_HTTP_POLICY="${REPO_ROOT}/config/nginx/http/http-transport-policy.conf"
DEV_HTTPS_POLICY="${REPO_ROOT}/config/nginx/http/https-response-policy.conf"
ROUTING="${REPO_ROOT}/config/nginx/http/routing.conf"
GLOBAL_CONFIG="${TEST_ROOT}/nginx.conf"
cp "${REPO_ROOT}/config/nginx/nginx.conf" "${GLOBAL_CONFIG}"

docker run --rm --network=none --entrypoint sh "${BASE_IMAGE}" -c 'test -x /scripts/nginx-production-entrypoint.sh' \
  || fail "shared image is missing its TLS-aware entrypoint"
grep -Fq 'CMD ["/scripts/nginx-production-entrypoint.sh"]' "${DOCKERFILE}" \
  || fail "production image does not execute its TLS-aware entrypoint"
grep -Fq 'location ^~ /simulator-ui/' "${ROUTING}" \
  || fail "nginx does not expose the simulator browser assets"
grep -Fq 'proxy_pass http://payment-simulator:18082;' "${ROUTING}" \
  || fail "nginx does not route simulator browser surfaces to the internal service"
if grep -Eq 'location.*(/myscoutee/v1|/v1/|/v2/|/v4/|/healthz)' "${ROUTING}"; then
  fail "nginx exposes a private payment simulator provider/control route"
fi

mkdir -p \
  "${TEST_ROOT}/keys" \
  "${TEST_ROOT}/letsencrypt/live/transport.test" \
  "${TEST_ROOT}/acme/.well-known/acme-challenge" \
  "${TEST_ROOT}/html/assets" \
  "${TEST_ROOT}/stream"

openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "${TEST_ROOT}/keys/custom.key" \
  -out "${TEST_ROOT}/keys/custom.crt" \
  -days 1 \
  -subj "/CN=transport.test" >/dev/null 2>&1
cp "${TEST_ROOT}/keys/custom.crt" \
  "${TEST_ROOT}/letsencrypt/live/transport.test/fullchain.pem"
cp "${TEST_ROOT}/keys/custom.key" \
  "${TEST_ROOT}/letsencrypt/live/transport.test/privkey.pem"
printf 'console.log("transport-policy");\n' > "${TEST_ROOT}/html/app-TRANSPORT.js"
mkdir -p "${TEST_ROOT}/html/media"
printf 'font-fixture\n' > "${TEST_ROOT}/html/media/roboto-1A2B3C4D.woff2"
printf 'font-fixture\n' > "${TEST_ROOT}/html/media/material-icons-A1B2C3D4.woff"
printf 'font-fixture\n' > "${TEST_ROOT}/html/media/custom-font.woff2"

printf '<!doctype html><html><head>\n' > "${TEST_ROOT}/html/index.html"
sed -n '/<script id="myscoutee-\(runtime-status\|landing-debug\|landing-debug-context\|consent-auto\)"/p' "${REPO_ROOT}/frontend/src/index.html" >> "${TEST_ROOT}/html/index.html"
sed -n '/<!--# if expr="\$myscoutee_landing_debug = 1" -->/,/<!--# endif -->/p' "${REPO_ROOT}/frontend/src/index.html" >> "${TEST_ROOT}/html/index.html"
printf '</head><body>transport-policy</body></html>\n' >> "${TEST_ROOT}/html/index.html"
printf 'console.log("service-worker");\n' > "${TEST_ROOT}/html/app-sw.js"
printf '%s\n' '{"version":"1.0.0","buildId":"transport-policy"}' \
  > "${TEST_ROOT}/html/app-version.json"
printf '%s\n' '{"name":"transport-policy","start_url":"/","scope":"/"}' \
  > "${TEST_ROOT}/html/manifest.webmanifest"
printf 'acme-token\n' \
  > "${TEST_ROOT}/acme/.well-known/acme-challenge/test-token"
cp "${REPO_ROOT}/config/nginx/stream/mongodb.conf" \
  "${TEST_ROOT}/stream/mongodb.conf"

docker_args() {
  local config_dir="$1"

  printf '%s\n' \
    --add-host profilemanagement:127.0.0.1 \
    --add-host mcp:127.0.0.1 \
    --add-host payment-simulator:127.0.0.1 \
    --add-host mongodb:127.0.0.1 \
    -e DOMAIN=transport.test \
    -e MYSCOUTEE_RUNTIME_STATUS_TOKEN=0123456789abcdef0123456789abcdef \
    -v "${GLOBAL_CONFIG}:/etc/nginx/nginx.conf:ro" \
    -v "${SPRING_TEMPLATE}:/etc/nginx/myscoutee-templates/spring.conf:ro" \
    -v "${config_dir}:/etc/nginx/conf.d" \
    -v "${TEST_ROOT}/stream:/etc/nginx/stream_conf.d:ro" \
    -v "${TEST_ROOT}/html:/usr/share/nginx/html:ro" \
    -v "${TEST_ROOT}/keys:/etc/nginx/keys:ro" \
    -v "${TEST_ROOT}/letsencrypt:/etc/letsencrypt:ro" \
    -v "${TEST_ROOT}/acme:/var/www/certbot:ro"
}

prepare_config_dir() {
  local name="$1"
  local http_policy="$2"
  local https_policy="$3"
  local config_dir="${TEST_ROOT}/${name}-conf"

  mkdir -p "${config_dir}"
  cp "${REPO_ROOT}/config/nginx/http/routing.conf" \
    "${config_dir}/routing.conf"
  cp "${REPO_ROOT}/config/nginx/http/runtime-status.conf" "${config_dir}/runtime-status.conf"
  if [[ "${http_policy}" == "${PROD_HTTP_POLICY}" ]]; then
    cp "${REPO_ROOT}/config/nginx/http/update-status.prod.conf" "${config_dir}/update-status.prod.conf"
    printf '\ninclude /etc/nginx/conf.d/update-status.prod.conf;\n' >> "${config_dir}/routing.conf"
  fi
  cp "${http_policy}" "${config_dir}/http-transport-policy.conf"
  cp "${https_policy}" "${config_dir}/https-response-policy.conf"
  printf '%s' "${config_dir}"
}

start_nginx() {
  local name="$1"
  local http_policy="$2"
  local https_policy="$3"
  local config_dir container http_binding https_binding
  local -a args=()

  config_dir="$(prepare_config_dir "${name}" "${http_policy}" "${https_policy}")"
  container="myscoutee-nginx-${name}-$$"
  mapfile -t args < <(docker_args "${config_dir}")
  RUNNING_CONTAINERS+=("${container}")

  docker run --rm -d \
    --name "${container}" \
    -p 127.0.0.1::80 \
    -p 127.0.0.1::443 \
    "${args[@]}" \
    -e LETSENCRYPT_ENABLED=false \
    -e NGINX_TLS_CERTIFICATE_PATH=/etc/nginx/keys/custom.crt \
    -e NGINX_TLS_CERTIFICATE_KEY_PATH=/etc/nginx/keys/custom.key \
    "${BASE_IMAGE}" \
    bash /scripts/nginx-production-entrypoint.sh >/dev/null

  http_binding="$(docker port "${container}" 80/tcp)"
  https_binding="$(docker port "${container}" 443/tcp)"
  STARTED_CONTAINER="${container}"
  STARTED_HTTP_PORT="${http_binding##*:}"
  STARTED_HTTPS_PORT="${https_binding##*:}"
  STARTED_CONFIG_DIR="${config_dir}"
}

wait_for_health() {
  local port="$1"
  local attempt

  for attempt in {1..50}; do
    if [[ "$(curl -sS -o /dev/null -w '%{http_code}' \
      "http://127.0.0.1:${port}/nginx-health" 2>/dev/null || true)" == "200" ]]; then
      return 0
    fi
    sleep 0.1
  done
  fail "isolated Nginx did not become healthy"
}

assert_header() {
  local headers="$1"
  local expected="$2"

  grep -Eiq "${expected}" "${headers}" \
    || fail "expected response header was missing: ${expected}"
}

assert_no_header() {
  local headers="$1"
  local unexpected="$2"

  if grep -Eiq "${unexpected}" "${headers}"; then
    fail "unexpected response header was present: ${unexpected}"
  fi
}

start_nginx prod "${PROD_HTTP_POLICY}" "${PROD_HTTPS_POLICY}"
prod_container="${STARTED_CONTAINER}"
prod_http_port="${STARTED_HTTP_PORT}"
prod_https_port="${STARTED_HTTPS_PORT}"
prod_config_dir="${STARTED_CONFIG_DIR}"
wait_for_health "${prod_http_port}"

runtime_status_headers="${TEST_ROOT}/runtime-status.headers"
runtime_status_code="$(curl -skS -D "${runtime_status_headers}" -o "${TEST_ROOT}/runtime-status.json" \
  -w '%{http_code}' "https://127.0.0.1:${prod_https_port}/api/runtime-status")"
[[ "${runtime_status_code}" == 200 ]] || fail "runtime status is not served by nginx while the backend is absent"
assert_header "${runtime_status_headers}" '^Cache-Control: no-store'
assert_header "${runtime_status_headers}" '^Content-Type: application/json'
assert_header "${runtime_status_headers}" '^X-Content-Type-Options: nosniff'
python3 - "${TEST_ROOT}/runtime-status.json" <<'PY'
import json, sys, time
status = json.load(open(sys.argv[1]))
assert set(status) == {'ready', 'known', 'checkedAt'}
assert status['known'] is True
assert status['ready'] is False
assert abs(time.time() - status['checkedAt']) < 10
PY
[[ "$(curl -skS -o /dev/null -w '%{http_code}' -X POST "https://127.0.0.1:${prod_https_port}/api/runtime-status")" == 403 ]] \
  || fail "runtime status accepted a write method"

[[ "$(curl -sS "http://127.0.0.1:${prod_http_port}/nginx-health")" == "UP" ]] \
  || fail "production health endpoint is not available over HTTP"
[[ "$(curl -sS "http://127.0.0.1:${prod_http_port}/.well-known/acme-challenge/test-token")" == "acme-token" ]] \
  || fail "production ACME challenge path is redirected or unavailable"

prod_redirect_headers="${TEST_ROOT}/prod-redirect.headers"
prod_redirect_status="$(curl -sS -o /dev/null -D "${prod_redirect_headers}" \
  -H 'Host: transport.test' -w '%{http_code}' \
  "http://127.0.0.1:${prod_http_port}/api/auth/me")"
[[ "${prod_redirect_status}" == "308" ]] \
  || fail "production application HTTP request was not redirected"
assert_header "${prod_redirect_headers}" '^Location: https://transport\.test/api/auth/me'

prod_forged_host_headers="${TEST_ROOT}/prod-forged-host.headers"
prod_forged_host_status="$(curl -sS -o /dev/null -D "${prod_forged_host_headers}" \
  -H 'Host: forged-host.invalid' -w '%{http_code}' \
  "http://127.0.0.1:${prod_http_port}/api/auth/me")"
[[ "${prod_forged_host_status}" == "308" ]] \
  || fail "production request with a forged Host header was not safely redirected"
assert_header "${prod_forged_host_headers}" '^Location: https://transport\.test/api/auth/me'
assert_no_header "${prod_forged_host_headers}" '^Location: https://forged-host\.invalid'

prod_asset_headers="${TEST_ROOT}/prod-asset.headers"
curl -skS -o /dev/null -D "${prod_asset_headers}" \
  -H 'Host: transport.test' \
  "https://127.0.0.1:${prod_https_port}/app-TRANSPORT.js"
assert_header "${prod_asset_headers}" '^Strict-Transport-Security: max-age=31536000'
assert_header "${prod_asset_headers}" '^Cache-Control: public, max-age=31536000, immutable'

# Hash-named build fonts share the static bundle lifetime; media proxy queries do not.
for font in roboto-1A2B3C4D.woff2 material-icons-A1B2C3D4.woff; do
  font_headers="${TEST_ROOT}/${font}.headers"
  font_code="$(curl -skS -D "${font_headers}" -o /dev/null -w '%{http_code}' \
    "https://127.0.0.1:${prod_https_port}/media/${font}")"
  [[ "${font_code}" == 200 ]] || fail "hashed build font is not served: ${font}"
  assert_header "${font_headers}" '^Cache-Control: public, max-age=31536000, immutable'
  assert_header "${font_headers}" '^X-Content-Type-Options: nosniff'
  assert_header "${font_headers}" '^Strict-Transport-Security: max-age=31536000'
done
curl -skS -D "${TEST_ROOT}/named-font.headers" -o /dev/null \
  "https://127.0.0.1:${prod_https_port}/media/custom-font.woff2"
assert_header "${TEST_ROOT}/named-font.headers" '^Cache-Control: no-cache, no-store, must-revalidate'
assert_no_header "${TEST_ROOT}/named-font.headers" 'immutable'
[[ "$(curl -skS -o /dev/null -w '%{http_code}' \
  "https://127.0.0.1:${prod_https_port}/media/missing-1A2B3C4D.woff2")" == 404 ]] \
  || fail "missing hashed font fell through to the SPA"
curl -skS -D "${TEST_ROOT}/public-media.headers" -o /dev/null \
  "https://127.0.0.1:${prod_https_port}/media/public?key=images/roboto-1A2B3C4D.woff2"
assert_no_header "${TEST_ROOT}/public-media.headers" 'immutable'

prod_root_headers="${TEST_ROOT}/prod-root.headers"
curl -skS -o "${TEST_ROOT}/index-response.html" -D "${prod_root_headers}" \
  -H 'Host: transport.test' \
  "https://127.0.0.1:${prod_https_port}/"
assert_header "${prod_root_headers}" '^Strict-Transport-Security: max-age=31536000'
assert_header "${prod_root_headers}" '^Cache-Control: no-cache, no-store, must-revalidate'
assert_header "${prod_root_headers}" '^X-MyScoutee-Consent-Auto: 0'
grep -Eq 'id="myscoutee-consent-auto"[^>]*>0</script>' "${TEST_ROOT}/index-response.html" || fail "default disabled consent flag missing"
python3 - "${TEST_ROOT}/index-response.html" <<'PY'
import json, re, sys, time
html = open(sys.argv[1]).read()
snapshot = re.search(r'<script id="myscoutee-runtime-status"[^>]*>(.*?)</script>', html, re.S)
assert snapshot is not None, 'initial availability missing from HTML head'
assert '<!--#' not in snapshot[1], 'nginx did not process the canonical SSI directive'
status = json.loads(snapshot[1])
assert status['ready'] is False and abs(time.time() - status['checkedAt']) < 10
PY

# The same nginx variable gates both early HTML activation and the nginx-only sink.
[[ "$(curl -skS -o /dev/null -w '%{http_code}' -X POST "https://127.0.0.1:${prod_https_port}/__landing-debug?d=off")" == 404 ]] || fail "debug endpoint is enabled by default"
grep -Eq 'id="myscoutee-landing-debug"[^>]*>0</script>' "${TEST_ROOT}/index-response.html" || fail "disabled probe flag not embedded"
if grep -Fq 'id="myscoutee-landing-debug-recorder"' "${TEST_ROOT}/index-response.html"; then
  fail "disabled diagnostics still request the recorder"
fi
python3 - "${GLOBAL_CONFIG}" <<'PYDEBUG'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text();p.write_text(s.replace('map $host $myscoutee_landing_debug { default 0; }', 'map $host $myscoutee_landing_debug { default 1; }').replace('map $host $myscoutee_consent_auto { default 0; }', 'map $host $myscoutee_consent_auto { default 1; }'))
PYDEBUG
docker exec "${prod_container}" nginx -t >/dev/null
docker exec "${prod_container}" nginx -s reload
for attempt in {1..30}; do
  debug_code="$(curl -skS -o /dev/null -w '%{http_code}' -X POST "https://127.0.0.1:${prod_https_port}/__landing-debug?d=nginx-test")"
  [[ "${debug_code}" == 204 ]] && break
  sleep 0.1
done
[[ "${debug_code}" == 204 ]] || fail "enabled debug POST did not terminate at nginx"
for consent_path in / /game; do
  curl -skS -D "${TEST_ROOT}/consent.headers" -o "${TEST_ROOT}/consent.html" \
    -H 'X-MyScoutee-Consent-Auto: 0' "https://127.0.0.1:${prod_https_port}${consent_path}"
  assert_header "${TEST_ROOT}/consent.headers" '^X-MyScoutee-Consent-Auto: 1'
  grep -Eq 'id="myscoutee-consent-auto"[^>]*>1</script>' "${TEST_ROOT}/consent.html" || fail "enabled consent flag missing on ${consent_path}"
  grep -Fq 'id="myscoutee-landing-debug-recorder"' "${TEST_ROOT}/consent.html" || fail "enabled diagnostics lost their recorder"
done

[[ "$(curl -skS -o /dev/null -w '%{http_code}' "https://127.0.0.1:${prod_https_port}/__landing-debug?d=nginx-test")" == 405 ]] || fail "debug endpoint accepted GET"
curl -skS "https://127.0.0.1:${prod_https_port}/" | grep -Eq 'id="myscoutee-landing-debug"[^>]*>1</script>' || fail "enabled flag not embedded"
curl -skS -H 'Sec-Purpose: prefetch;prerender' -H 'Sec-Fetch-User: ?1' "https://127.0.0.1:${prod_https_port}/" | grep -Fq 'id="myscoutee-landing-debug-context" type="application/json">[2,1]</script>' || fail "original HTML prerender/user hints not embedded"
curl -skS -H 'X-Purpose: preview' "https://127.0.0.1:${prod_https_port}/" | grep -Fq 'id="myscoutee-landing-debug-context" type="application/json">[1,0]</script>' || fail "original HTML preview hint not embedded"
curl -skS -H 'X-Purpose: <script>private</script>' "https://127.0.0.1:${prod_https_port}/" | grep -Fq 'id="myscoutee-landing-debug-context" type="application/json">[0,0]</script>' || fail "arbitrary request header escaped the numeric allowlist"
docker exec "${prod_container}" cat /var/log/nginx/landing-debug.log | grep -Fq '/__landing-debug?d=nginx-test' || fail "dedicated debug file is empty"
if docker logs "${prod_container}" 2>&1 | grep -Fq '/__landing-debug?'; then fail "debug traffic leaked into the ordinary access log"; fi
python3 - "${GLOBAL_CONFIG}" <<'PYDEBUG'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text();p.write_text(s.replace('map $host $myscoutee_landing_debug { default 1; }', 'map $host $myscoutee_landing_debug { default 0; }'))
PYDEBUG
docker exec "${prod_container}" nginx -s reload

prod_deep_link_headers="${TEST_ROOT}/prod-deep-link.headers"
curl -skS -o /dev/null -D "${prod_deep_link_headers}" \
  -H 'Host: transport.test' \
  "https://127.0.0.1:${prod_https_port}/game"
assert_header "${prod_deep_link_headers}" '^Cache-Control: no-cache, no-store, must-revalidate'

prod_worker_headers="${TEST_ROOT}/prod-worker.headers"
curl -skS -o /dev/null -D "${prod_worker_headers}" \
  -H 'Host: transport.test' \
  "https://127.0.0.1:${prod_https_port}/app-sw.js"
assert_header "${prod_worker_headers}" '^Cache-Control: no-cache, no-store, must-revalidate'
assert_no_header "${prod_worker_headers}" 'immutable'

prod_version_headers="${TEST_ROOT}/prod-version.headers"
curl -skS -o /dev/null -D "${prod_version_headers}" \
  -H 'Host: transport.test' \
  "https://127.0.0.1:${prod_https_port}/app-version.json"
assert_header "${prod_version_headers}" '^Cache-Control: no-cache, no-store, must-revalidate'
assert_no_header "${prod_version_headers}" 'immutable'

prod_manifest_headers="${TEST_ROOT}/prod-manifest.headers"
curl -skS -o /dev/null -D "${prod_manifest_headers}" \
  -H 'Host: transport.test' \
  "https://127.0.0.1:${prod_https_port}/manifest.webmanifest"
assert_header \
  "${prod_manifest_headers}" \
  '^Content-Type: application/manifest\+json'
assert_header "${prod_manifest_headers}" '^Cache-Control: no-cache'

# Locations with their own Cache-Control must retain the production security policy.
for headers in "${prod_root_headers}" "${prod_deep_link_headers}" "${prod_worker_headers}" \
  "${prod_version_headers}" "${prod_asset_headers}" "${prod_manifest_headers}"; do
  assert_header "${headers}" '^X-Content-Type-Options: nosniff'
  assert_header "${headers}" '^X-Frame-Options: DENY'
  assert_header "${headers}" '^Referrer-Policy: strict-origin-when-cross-origin'
  assert_header "${headers}" "^Content-Security-Policy: frame-ancestors 'none'; object-src 'none'; base-uri 'self'"
done

grep -Fq 'server_name transport.test;' "${prod_config_dir}/spring.conf" \
  || fail "DOMAIN was not rendered into production Nginx"
grep -Fq 'ssl_certificate /etc/nginx/keys/custom.crt;' "${prod_config_dir}/spring.conf" \
  || fail "operator-managed certificate path was not selected"
grep -Fq 'ssl_certificate_key /etc/nginx/keys/custom.key;' "${prod_config_dir}/spring.conf" \
  || fail "operator-managed private-key path was not selected"

start_nginx dev "${DEV_HTTP_POLICY}" "${DEV_HTTPS_POLICY}"
dev_container="${STARTED_CONTAINER}"
dev_http_port="${STARTED_HTTP_PORT}"
dev_https_port="${STARTED_HTTPS_PORT}"
dev_config_dir="${STARTED_CONFIG_DIR}"
wait_for_health "${dev_http_port}"

dev_http_headers="${TEST_ROOT}/dev-http.headers"
dev_http_status="$(curl -sS -o /dev/null -D "${dev_http_headers}" \
  -H 'Host: transport.test' -w '%{http_code}' \
  "http://127.0.0.1:${dev_http_port}/app-TRANSPORT.js")"
[[ "${dev_http_status}" == "200" ]] \
  || fail "development policy unexpectedly redirected HTTP"
assert_no_header "${dev_http_headers}" '^Strict-Transport-Security:'

dev_https_headers="${TEST_ROOT}/dev-https.headers"
curl -skS -o /dev/null -D "${dev_https_headers}" \
  -H 'Host: transport.test' \
  "https://127.0.0.1:${dev_https_port}/app-TRANSPORT.js"
assert_no_header "${dev_https_headers}" '^Strict-Transport-Security:'
assert_header "${dev_https_headers}" '^Cache-Control: public, max-age=31536000, immutable'

le_config_dir="$(prepare_config_dir letsencrypt "${PROD_HTTP_POLICY}" "${PROD_HTTPS_POLICY}")"
mapfile -t le_args < <(docker_args "${le_config_dir}")
docker run --rm \
  "${le_args[@]}" \
  -e LETSENCRYPT_ENABLED=true \
  -e NGINX_CONFIG_TEST_ONLY=true \
  "${BASE_IMAGE}" \
  bash /scripts/nginx-production-entrypoint.sh >/dev/null

grep -Fq \
  'ssl_certificate /etc/letsencrypt/live/transport.test/fullchain.pem;' \
  "${le_config_dir}/spring.conf" \
  || fail "LETSENCRYPT_ENABLED did not select the domain certificate"
grep -Fq \
  'ssl_certificate_key /etc/letsencrypt/live/transport.test/privkey.pem;' \
  "${le_config_dir}/spring.conf" \
  || fail "LETSENCRYPT_ENABLED did not select the domain private key"

echo "Nginx transport policy tests passed."
