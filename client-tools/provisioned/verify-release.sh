#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  verify-release.sh ARTIFACT RELEASE_MANIFEST RELEASE_PUBLIC_KEY TRUSTED_SPKI_SHA256

Verifies a @@DISPLAY_NAME@@ Debian package or client-tools archive against
detached Ed25519 release metadata. Obtain the trusted key fingerprint through
an independent channel. Its canonical form is:

  sha256:<64 lowercase hexadecimal characters>
USAGE
}

fail() {
  echo "release verification failed: $1" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -eq 4 ]] || {
  usage
  exit 2
}

artifact_path="$1"
manifest_path="$2"
public_key_path="$3"
trusted_fingerprint="$4"

for command_name in base64 dpkg-deb jq od openssl sha256sum stat tar; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "missing required command: ${command_name}"
done
for input_path in "$artifact_path" "$manifest_path" "$public_key_path"; do
  [[ -f "$input_path" && ! -L "$input_path" ]] \
    || fail "input must be a regular, non-symbolic-link file: ${input_path}"
done
[[ "$trusted_fingerprint" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || fail "trusted public-key fingerprint is not canonical"

work_dir="$(mktemp -d /tmp/@@PACKAGE_NAME@@-release-verification.XXXXXX)"
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

public_der="${work_dir}/release-public-key.der"
if ! openssl pkey \
    -pubin \
    -in "$public_key_path" \
    -outform DER \
    -out "$public_der" >/dev/null 2>&1; then
  fail "release public key is not a valid public key"
fi
[[ "$(stat -c '%s' "$public_der")" == "44" ]] \
  || fail "release public key is not an Ed25519 SPKI key"
public_der_prefix="$(
  od -An -tx1 -N12 "$public_der" | tr -d ' \n'
)"
[[ "$public_der_prefix" == "302a300506032b6570032100" ]] \
  || fail "release public key is not canonical Ed25519 SPKI DER"

public_key_sha256="$(sha256sum "$public_der" | awk '{ print $1 }')"
actual_fingerprint="sha256:${public_key_sha256}"
[[ "$actual_fingerprint" == "$trusted_fingerprint" ]] \
  || fail "release public key does not match the independently trusted fingerprint"
expected_key_id="pkey_${public_key_sha256:0:32}"

if ! jq -e '
    type == "object"
    and (keys | sort)
      == (["artifacts", "channel", "schemaVersion", "signingKeyId", "version"] | sort)
    and .schemaVersion == 1
    and (.version | type == "string"
      and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))
    and (.channel | type == "string"
      and test("^[a-z][a-z0-9._-]{0,31}$"))
    and (.signingKeyId | type == "string"
      and test("^pkey_[0-9a-f]{32}$"))
    and (.artifacts | type == "array" and length == 2)
    and ([.artifacts[].purpose] == ["debian-package", "client-tools"])
    and all(.artifacts[];
      type == "object"
      and (keys | sort)
        == (["filename", "purpose", "sha256", "signature", "sizeBytes"] | sort)
      and (.filename | type == "string"
        and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$"))
      and (.sizeBytes | type == "number" and . > 0 and floor == .)
      and (.sha256 | type == "string"
        and test("^sha256:[0-9a-f]{64}$"))
      and (.signature | type == "string"
        and test("^[A-Za-z0-9+/]{86}==$")))
  ' "$manifest_path" >/dev/null; then
  fail "release manifest schema or canonical values are invalid"
fi

release_version="$(jq -r '.version' "$manifest_path")"
release_channel="$(jq -r '.channel' "$manifest_path")"
manifest_key_id="$(jq -r '.signingKeyId' "$manifest_path")"
[[ "$manifest_key_id" == "$expected_key_id" ]] \
  || fail "release manifest signing key ID does not match the trusted public key"

artifact_basename="$(basename -- "$artifact_path")"
artifact_index="$(
  jq -r --arg filename "$artifact_basename" '
    [.artifacts | to_entries[] | select(.value.filename == $filename) | .key]
    | if length == 1 then .[0] else empty end
  ' "$manifest_path"
)"
[[ "$artifact_index" =~ ^[01]$ ]] \
  || fail "artifact filename is not declared exactly once by the release manifest"
artifact_purpose="$(
  jq -r --argjson index "$artifact_index" \
    '.artifacts[$index].purpose' "$manifest_path"
)"

case "$artifact_purpose" in
  debian-package)
    package_name="$(dpkg-deb -f "$artifact_path" Package)"
    package_version="$(dpkg-deb -f "$artifact_path" Version)"
    package_architecture="$(dpkg-deb -f "$artifact_path" Architecture)"
    [[ "$package_name" == "@@PACKAGE_NAME@@" ]] \
      || fail "Debian artifact package name is not @@PACKAGE_NAME@@"
    [[ "$package_version" == "$release_version" ]] \
      || fail "Debian artifact version does not match the release manifest"
    [[ "$package_architecture" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] \
      || fail "Debian artifact architecture is invalid"
    [[ "$artifact_basename" == \
      "@@PACKAGE_NAME@@_${release_version}_${package_architecture}.deb" ]] \
      || fail "release manifest has a non-canonical Debian filename"
    message_domain="@@PACKAGE_DOMAIN@@"
    ;;
  client-tools)
    archive_version="$(
      tar -xOzf "$artifact_path" ./VERSION 2>/dev/null | tr -d '\r\n'
    )"
    [[ "$archive_version" == "$release_version" ]] \
      || fail "client-tools archive version does not match the release manifest"
    [[ "$artifact_basename" == \
      "@@PACKAGE_NAME@@-client-tools_${release_version}.tar.gz" ]] \
      || fail "release manifest has a non-canonical client-tools filename"
    message_domain="@@CLIENT_DOMAIN@@"
    ;;
  *)
    fail "artifact purpose is unsupported"
    ;;
esac

declared_size="$(
  jq -r --argjson index "$artifact_index" \
    '.artifacts[$index].sizeBytes' "$manifest_path"
)"
declared_sha="$(
  jq -r --argjson index "$artifact_index" \
    '.artifacts[$index].sha256' "$manifest_path"
)"
declared_signature="$(
  jq -r --argjson index "$artifact_index" \
    '.artifacts[$index].signature' "$manifest_path"
)"
actual_size="$(stat -c '%s' "$artifact_path")"
actual_sha="sha256:$(sha256sum "$artifact_path" | awk '{ print $1 }')"
[[ "$actual_size" == "$declared_size" ]] \
  || fail "artifact size does not match the signed release metadata"
[[ "$actual_sha" == "$declared_sha" ]] \
  || fail "artifact SHA-256 does not match the signed release metadata"

signature_path="${work_dir}/artifact.signature"
message_path="${work_dir}/artifact.message"
if ! printf '%s' "$declared_signature" \
    | base64 --decode > "$signature_path" 2>/dev/null; then
  fail "artifact signature is not valid base64"
fi
[[ "$(stat -c '%s' "$signature_path")" == "64" ]] \
  || fail "artifact signature is not an Ed25519 signature"
[[ "$(base64 -w 0 "$signature_path")" == "$declared_signature" ]] \
  || fail "artifact signature is not canonical padded base64"

printf '%s\n' \
  "$message_domain" \
  "$release_version" \
  "$release_channel" \
  "$declared_size" \
  "$declared_sha" \
  > "$message_path"
if ! openssl pkeyutl \
    -verify \
    -pubin \
    -inkey "$public_key_path" \
    -rawin \
    -in "$message_path" \
    -sigfile "$signature_path" >/dev/null 2>&1; then
  fail "artifact metadata signature is invalid"
fi

printf 'Release artifact verified: %s\n' "$artifact_basename"
printf 'Release: %s (%s)\n' "$release_version" "$release_channel"
printf 'Signing key: %s (%s)\n' "$expected_key_id" "$actual_fingerprint"
