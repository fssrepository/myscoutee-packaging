#!/usr/bin/env bash
set -euo pipefail
umask 077

# This is the narrow privileged boundary for operator-approved package
# updates. Inputs are local, fixed-format files. URLs and commands are never
# accepted from an update request.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/release-project.sh"
policy_owner=0
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then policy_owner="$(id -u)"; fi
release_project_load "${SCRIPT_DIR}" "${policy_owner}" || {
  echo 'The package-owned release project policy is missing or unsafe.' >&2
  exit 1
}
STATE_DIR="${MYSCOUTEE_UPDATE_STATE_DIR:-/var/lib/${RELEASE_PROJECT_NAME}/update}"
CACHE_DIR="${MYSCOUTEE_UPDATE_CACHE_DIR:-/var/cache/${RELEASE_PROJECT_NAME}-update}"
AUDIT_DIR="${MYSCOUTEE_UPDATE_AUDIT_DIR:-/var/log/${RELEASE_PROJECT_NAME}/update}"
RELEASE_PUBLIC_KEY="${MYSCOUTEE_UPDATE_RELEASE_PUBLIC_KEY:-/etc/${RELEASE_PROJECT_NAME}/update/release-public-key.pem}"
SAFE_COPY_HELPER="${MYSCOUTEE_UPDATE_SAFE_COPY_HELPER:-${SCRIPT_DIR}/myscoutee-safe-copy.py}"
RESTART_HELPER="${MYSCOUTEE_UPDATE_RESTART_HELPER:-${SCRIPT_DIR}/restart-update-stack.sh}"
IMAGE_CONTENT_FINGERPRINT_HELPER="${SCRIPT_DIR}/image-content-fingerprint.sh"
INSTALLED_MANIFEST_PATH="${MYSCOUTEE_UPDATE_INSTALLED_MANIFEST_PATH:-${RELEASE_PROJECT_ROOT}/packaging/IMAGE-MANIFEST.json}"
PACKAGE_NAME="${RELEASE_PROJECT_NAME}"
MAX_ARTIFACT_BYTES="${MYSCOUTEE_UPDATE_MAX_ARTIFACT_BYTES:-4294967296}"
MAX_REQUEST_BYTES="${MYSCOUTEE_UPDATE_MAX_REQUEST_BYTES:-65536}"
MAX_IMAGE_MANIFEST_BYTES=65536
MIN_FREE_BYTES="${MYSCOUTEE_UPDATE_MIN_FREE_BYTES:-536870912}"
HEALTH_TIMEOUT_SECONDS="${MYSCOUTEE_UPDATE_HEALTH_TIMEOUT_SECONDS:-300}"
CACHE_RETENTION_JOBS="${MYSCOUTEE_UPDATE_CACHE_RETENTION_JOBS:-2}"
UPDATE_ENABLED="${MYSCOUTEE_UPDATE_ENABLED:-false}"
API_USER_ID="${MYSCOUTEE_API_USER_ID:-$RELEASE_PROJECT_UID}"
API_GROUP_ID="${MYSCOUTEE_API_GROUP_ID:-$RELEASE_PROJECT_GID}"
WORKER_USER_ID=0
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  # Tests source the worker without root; production execution never accepts
  # an override for the owner of privileged state.
  WORKER_USER_ID="${MYSCOUTEE_UPDATE_WORKER_USER_ID:-0}"
fi

INBOX_DIR="${STATE_DIR}/inbox"
STAGING_DIR="${INBOX_DIR}/staging"
REQUEST_DIR="${INBOX_DIR}/requests"
ARCHIVE_DIR="${STATE_DIR}/archive"
PROCESSING_DIR="${ARCHIVE_DIR}/processing"
COMPLETED_DIR="${ARCHIVE_DIR}/completed"
FAILED_DIR="${ARCHIVE_DIR}/failed"
REJECTED_DIR="${ARCHIVE_DIR}/rejected"
RUNTIME_DIR="${STATE_DIR}/runtime"
JOBS_DIR="${RUNTIME_DIR}/jobs"
CACHE_JOBS_DIR="${CACHE_DIR}/jobs"

CURRENT_ROLLBACK_JOB=""
CURRENT_REQUEST=""
CURRENT_CLAIM_DIR=""
CURRENT_JOB_ID=""
CURRENT_REQUESTED_AT=""
CURRENT_REQUESTED_BY=""
CURRENT_MANIFEST_HASH=""
CURRENT_RELEASE_VERSION=""
CURRENT_CHANNEL=""
CURRENT_ARTIFACT_NAME=""
CURRENT_ARTIFACT_SIZE=0
CURRENT_ARTIFACT_SHA256=""
CURRENT_PACKAGE_SIGNING_KEY_ID=""
CURRENT_PACKAGE_SIGNATURE=""
CURRENT_JOB_DIR=""
CURRENT_STATUS_FILE=""
CURRENT_EVENTS_FILE=""
CURRENT_LOG_FILE=""
CURRENT_AUDIT_REQUEST=""
CURRENT_BACKUP_PATH=""
CURRENT_VERSION=""
CURRENT_IMAGE_MANIFEST=""
CURRENT_CACHED_ARTIFACT=""
JOB_CONTEXT_STATE=""

timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

install_numeric_owned_directory() {
  local mode="$1"
  local owner_uid="$2"
  local owner_gid="$3"
  shift 3

  [[ "${owner_uid}" =~ ^[0-9]+$ && "${owner_gid}" =~ ^[0-9]+$ ]] || {
    echo "Update directory ownership must use numeric IDs." >&2
    return 1
  }
  install -d -m "${mode}" -- "$@"
  chown "+${owner_uid}:+${owner_gid}" -- "$@"
  chmod "${mode}" -- "$@"
}

fsync_path() {
  sync -f "$1"
}

is_terminal_phase() {
  case "$1" in
    COMPLETED|FAILED|REJECTED|RECOVERY_REQUIRED)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

current_phase() {
  if [[ -f "${CURRENT_STATUS_FILE}" && ! -L "${CURRENT_STATUS_FILE}" ]]; then
    jq -r '.phase // ""' "${CURRENT_STATUS_FILE}" 2>/dev/null || true
  fi
}

log_line() {
  local message="$1"

  [[ -n "${CURRENT_LOG_FILE}" ]] || return 0
  printf '%s %s\n' "$(timestamp)" "${message}" >> "${CURRENT_LOG_FILE}"
  fsync_path "${CURRENT_LOG_FILE}"
}

write_status() {
  local phase="$1"
  local percent="$2"
  local message="$3"
  local tmp receipt rollback=null

  if receipt="$(read_root_receipt "$RUNTIME_DIR/recovery.json")"; then
    rollback="$(jq -c --arg current "$CURRENT_VERSION" 'if .fromVersion == $current then {jobId,fromVersion,targetVersion,artifactSha256} else null end' <<< "$receipt")"
  fi
  tmp="$(mktemp "${CURRENT_JOB_DIR}/.status.XXXXXX")"
  jq -n \
    --arg schemaVersion "1" \
    --arg jobId "${CURRENT_JOB_ID}" \
    --arg phase "${phase}" \
    --argjson percent "${percent}" \
    --arg message "${message}" \
    --arg updatedAt "$(timestamp)" \
    --arg requestedAt "${CURRENT_REQUESTED_AT}" \
    --arg requestedBy "${CURRENT_REQUESTED_BY}" \
    --arg manifestHash "${CURRENT_MANIFEST_HASH}" \
    --arg currentVersion "${CURRENT_VERSION}" \
    --arg targetVersion "${CURRENT_RELEASE_VERSION}" \
    --arg channel "${CURRENT_CHANNEL}" \
    --arg artifactSha256 "${CURRENT_ARTIFACT_SHA256}" \
    --arg backupPath "${CURRENT_BACKUP_PATH}" \
    --argjson rollback "$rollback" \
    '{
      schemaVersion: ($schemaVersion | tonumber),
      jobId: $jobId,
      phase: $phase,
      percent: $percent,
      message: $message,
      updatedAt: $updatedAt,
      requestedAt: $requestedAt,
      requestedBy: $requestedBy,
      manifestHash: $manifestHash,
      currentVersion: $currentVersion,
      targetVersion: $targetVersion,
      channel: $channel,
      artifactSha256: $artifactSha256,
      rollback: $rollback,
      backupPath: (if $backupPath == "" then null else $backupPath end)
    }' > "${tmp}"
  chmod 0640 "${tmp}"
  chgrp "+${API_GROUP_ID}" -- "${tmp}"
  mv -f -- "${tmp}" "${CURRENT_STATUS_FILE}"
  jq -c . "${CURRENT_STATUS_FILE}" >> "${CURRENT_EVENTS_FILE}"
  chmod 0640 "${CURRENT_EVENTS_FILE}"
  chgrp "+${API_GROUP_ID}" -- "${CURRENT_EVENTS_FILE}"
  fsync_path "${CURRENT_STATUS_FILE}"
  fsync_path "${CURRENT_EVENTS_FILE}"
  fsync_path "${CURRENT_JOB_DIR}"
}

fail_job() {
  local message="$1"

  log_line "FAILED: ${message}"
  write_status "FAILED" 100 "${message}"
  return 1
}

recovery_required() {
  local message="$1"

  CURRENT_VERSION="$(installed_version)"
  log_line "RECOVERY_REQUIRED: ${message}"
  write_status "RECOVERY_REQUIRED" 100 "${message}"
  return 1
}

require_runtime() {
  local command_name

  for command_name in \
    jq openssl sha256sum base64 stat df dpkg dpkg-deb dpkg-query apt-get \
    systemctl docker python3 tar find sort sync; do
    command -v "${command_name}" >/dev/null 2>&1 || {
      echo "Required update command is missing: ${command_name}" >&2
      return 1
    }
  done
  [[ -x "${SAFE_COPY_HELPER}" && ! -L "${SAFE_COPY_HELPER}" ]] || {
    echo "The packaged safe-copy helper is missing or unsafe." >&2
    return 1
  }
  [[ -f "${IMAGE_CONTENT_FINGERPRINT_HELPER}" \
    && -x "${IMAGE_CONTENT_FINGERPRINT_HELPER}" \
    && ! -L "${IMAGE_CONTENT_FINGERPRINT_HELPER}" ]] || {
    echo "The packaged image fingerprint helper is missing or unsafe." >&2
    return 1
  }
  [[ "${MAX_ARTIFACT_BYTES}" =~ ^[1-9][0-9]*$ ]] || {
    echo "MYSCOUTEE_UPDATE_MAX_ARTIFACT_BYTES must be a positive integer." >&2
    return 1
  }
  [[ "${MAX_REQUEST_BYTES}" =~ ^[1-9][0-9]*$ ]] || {
    echo "MYSCOUTEE_UPDATE_MAX_REQUEST_BYTES must be a positive integer." >&2
    return 1
  }
  [[ "${MIN_FREE_BYTES}" =~ ^[0-9]+$ ]] || {
    echo "MYSCOUTEE_UPDATE_MIN_FREE_BYTES must be a non-negative integer." >&2
    return 1
  }
  [[ "${HEALTH_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]] || {
    echo "MYSCOUTEE_UPDATE_HEALTH_TIMEOUT_SECONDS must be a positive integer." >&2
    return 1
  }
  [[ "${CACHE_RETENTION_JOBS}" =~ ^[0-9]+$ ]] \
    && (( CACHE_RETENTION_JOBS <= 10 )) || {
    echo "MYSCOUTEE_UPDATE_CACHE_RETENTION_JOBS must be between 0 and 10." >&2
    return 1
  }
  [[ "${API_USER_ID}" =~ ^[0-9]+$ && "${API_GROUP_ID}" =~ ^[0-9]+$ \
    && "${WORKER_USER_ID}" =~ ^[0-9]+$ ]] || {
    echo "MyScoutee update user and group IDs must be numeric." >&2
    return 1
  }
}

prepare_directories() {
  local directory

  for directory in \
    "${STATE_DIR}" "${INBOX_DIR}" "${STAGING_DIR}" "${REQUEST_DIR}" \
    "${ARCHIVE_DIR}" "${PROCESSING_DIR}" "${COMPLETED_DIR}" "${FAILED_DIR}" \
    "${REJECTED_DIR}" "${RUNTIME_DIR}" "${JOBS_DIR}" "${CACHE_DIR}" \
    "${CACHE_JOBS_DIR}" "${AUDIT_DIR}"; do
    [[ "${directory}" == /* ]] || {
      echo "Update paths must be absolute." >&2
      return 1
    }
    if [[ -L "${directory}" ]]; then
      echo "Update path must not be a symbolic link: ${directory}" >&2
      return 1
    fi
  done

  install -d -m 0700 \
    "${STATE_DIR}" "${INBOX_DIR}" "${ARCHIVE_DIR}" "${PROCESSING_DIR}" \
    "${COMPLETED_DIR}" "${FAILED_DIR}" "${REJECTED_DIR}" "${RUNTIME_DIR}" \
    "${CACHE_DIR}" "${CACHE_JOBS_DIR}" "${AUDIT_DIR}"
  install_numeric_owned_directory \
    0700 "${API_USER_ID}" "${API_GROUP_ID}" \
    "${STAGING_DIR}" "${REQUEST_DIR}"
  install_numeric_owned_directory \
    2750 "${WORKER_USER_ID}" "${API_GROUP_ID}" "${RUNTIME_DIR}" "${JOBS_DIR}"
}

read_request() {
  local request_file="$1"
  local strict

  [[ -f "${request_file}" && ! -L "${request_file}" ]] || return 1
  strict="$(jq -r '
    type == "object"
    and ((keys - [
      "schema_version",
      "job_id",
      "requested_at",
      "requested_by",
      "manifest_hash",
      "release_version",
      "channel",
      "artifact_name",
      "artifact_size_bytes",
      "artifact_sha256",
      "package_signing_key_id",
      "package_signature",
      "rollback_job_id"
    ]) | length == 0)
    and (.schema_version == 1)
    and (.artifact_size_bytes | type == "number")
  ' "${request_file}" 2>/dev/null || true)"
  [[ "${strict}" == "true" ]] || return 1

  CURRENT_ROLLBACK_JOB="$(jq -r '.rollback_job_id // ""' "${request_file}")"
  [[ -z "$CURRENT_ROLLBACK_JOB" || "$CURRENT_ROLLBACK_JOB" =~ ^upd_[0-9a-f]{32}$ ]] || return 1
  CURRENT_BACKUP_PATH=""
  CURRENT_IMAGE_MANIFEST=""
  CURRENT_CACHED_ARTIFACT=""
  CURRENT_REQUEST="${request_file}"
  CURRENT_JOB_ID="$(jq -r '.job_id // ""' "${request_file}")"
  CURRENT_REQUESTED_AT="$(jq -r '.requested_at // ""' "${request_file}")"
  CURRENT_REQUESTED_BY="$(jq -r '.requested_by // ""' "${request_file}")"
  CURRENT_MANIFEST_HASH="$(jq -r '.manifest_hash // ""' "${request_file}")"
  CURRENT_RELEASE_VERSION="$(jq -r '.release_version // ""' "${request_file}")"
  CURRENT_CHANNEL="$(jq -r '.channel // ""' "${request_file}")"
  CURRENT_ARTIFACT_NAME="$(jq -r '.artifact_name // ""' "${request_file}")"
  CURRENT_ARTIFACT_SIZE="$(jq -r '.artifact_size_bytes // 0' "${request_file}")"
  CURRENT_ARTIFACT_SHA256="$(jq -r '.artifact_sha256 // ""' "${request_file}")"
  CURRENT_PACKAGE_SIGNING_KEY_ID="$(jq -r '.package_signing_key_id // ""' "${request_file}")"
  CURRENT_PACKAGE_SIGNATURE="$(jq -r '.package_signature // ""' "${request_file}")"

  [[ "${CURRENT_JOB_ID}" =~ ^upd_[0-9a-f]{32}$ ]] || return 1
  [[ "${CURRENT_REQUESTED_AT}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  date -u -d "${CURRENT_REQUESTED_AT}" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1 \
    || return 1
  [[ -n "${CURRENT_REQUESTED_BY}" && ${#CURRENT_REQUESTED_BY} -le 160 ]] \
    || return 1
  [[ "${CURRENT_REQUESTED_BY}" != *$'\n'* && "${CURRENT_REQUESTED_BY}" != *$'\r'* ]] \
    || return 1
  [[ "${CURRENT_MANIFEST_HASH}" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  [[ "${CURRENT_RELEASE_VERSION}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-qa\.[1-9][0-9]*)?$ ]] \
    || return 1
  dpkg --validate-version "$(debian_version "${CURRENT_RELEASE_VERSION}")" >/dev/null 2>&1 || return 1
  [[ "${CURRENT_CHANNEL}" =~ ^[a-z][a-z0-9._-]{0,31}$ ]] || return 1
  [[ "${CURRENT_ARTIFACT_NAME}" == "myscoutee.deb" ]] || return 1
  [[ "${CURRENT_ARTIFACT_SIZE}" =~ ^[1-9][0-9]*$ ]] || return 1
  (( CURRENT_ARTIFACT_SIZE <= MAX_ARTIFACT_BYTES )) || return 1
  [[ "${CURRENT_ARTIFACT_SHA256}" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  [[ "${CURRENT_PACKAGE_SIGNING_KEY_ID}" =~ ^pkey_[0-9a-f]{32}$ ]] || return 1
  [[ "${CURRENT_PACKAGE_SIGNATURE}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
}

initialize_job_paths() {
  CURRENT_JOB_DIR="${JOBS_DIR}/${CURRENT_JOB_ID}"
  CURRENT_STATUS_FILE="${CURRENT_JOB_DIR}/status.json"
  CURRENT_EVENTS_FILE="${CURRENT_JOB_DIR}/events.ndjson"
  CURRENT_LOG_FILE="${CURRENT_JOB_DIR}/install.log"
  CURRENT_AUDIT_REQUEST="${AUDIT_DIR}/${CURRENT_JOB_ID}/request.json"
}

ensure_job_output_files() {
  local path

  for path in "${CURRENT_EVENTS_FILE}" "${CURRENT_LOG_FILE}"; do
    if [[ -e "${path}" || -L "${path}" ]]; then
      [[ -f "${path}" && ! -L "${path}" ]] || return 1
    else
      : > "${path}"
    fi
    chmod 0640 "${path}"
    chgrp "+${API_GROUP_ID}" -- "${path}"
  done
}

prepare_job_context() {
  local audit_job_dir request_digest audit_digest

  initialize_job_paths
  audit_job_dir="${AUDIT_DIR}/${CURRENT_JOB_ID}"
  for path in "${CURRENT_JOB_DIR}" "${audit_job_dir}"; do
    [[ ! -L "${path}" ]] || return 1
  done

  if [[ ! -e "${CURRENT_JOB_DIR}" && ! -e "${audit_job_dir}" ]]; then
    install_numeric_owned_directory \
      2750 "${WORKER_USER_ID}" "${API_GROUP_ID}" "${CURRENT_JOB_DIR}"
    install -d -m 0700 "${audit_job_dir}"
    install -m 0600 "${CURRENT_REQUEST}" "${CURRENT_AUDIT_REQUEST}"
    ensure_job_output_files || return 1
    JOB_CONTEXT_STATE="new"
    return 0
  fi

  if [[ ! -d "${CURRENT_JOB_DIR}" ]]; then
    install_numeric_owned_directory \
      2750 "${WORKER_USER_ID}" "${API_GROUP_ID}" "${CURRENT_JOB_DIR}"
    JOB_CONTEXT_STATE="partial"
  fi
  if [[ ! -d "${audit_job_dir}" ]]; then
    install -d -m 0700 "${audit_job_dir}"
    install -m 0600 "${CURRENT_REQUEST}" "${CURRENT_AUDIT_REQUEST}"
    JOB_CONTEXT_STATE="partial"
  elif [[ ! -f "${CURRENT_AUDIT_REQUEST}" || -L "${CURRENT_AUDIT_REQUEST}" ]]; then
    install -m 0600 "${CURRENT_REQUEST}" "${CURRENT_AUDIT_REQUEST}"
    JOB_CONTEXT_STATE="partial"
  else
    request_digest="$(sha256sum "${CURRENT_REQUEST}" | awk '{ print $1 }')"
    audit_digest="$(sha256sum "${CURRENT_AUDIT_REQUEST}" | awk '{ print $1 }')"
    [[ "${request_digest}" == "${audit_digest}" ]] || return 1
  fi

  ensure_job_output_files || return 1
  [[ -n "${JOB_CONTEXT_STATE}" ]] || JOB_CONTEXT_STATE="existing"
}

extract_image_manifest() {
  local package_path="$1"
  local destination="$2"
  local tmp

  tmp="$(mktemp "${destination}.XXXXXX")"
  if ! dpkg-deb --fsys-tarfile "${package_path}" \
    | tar -xOf - ".${RELEASE_PROJECT_ROOT}/packaging/IMAGE-MANIFEST.json" > "${tmp}" 2>/dev/null; then
    rm -f -- "${tmp}"
    return 1
  fi
  if [[ ! -s "${tmp}" ]] \
    || (( $(stat -c '%s' "${tmp}") > MAX_IMAGE_MANIFEST_BYTES )); then
    rm -f -- "${tmp}"
    return 1
  fi
  chmod 0600 "${tmp}"
  mv -f -- "${tmp}" "${destination}"
}

validate_image_manifest() {
  local manifest="$1"

  release_project_validate_manifest "${manifest}" "${CURRENT_RELEASE_VERSION}"
}

verify_and_cache_artifact() {
  local cache_job_dir cached_artifact actual_size actual_digest
  local package_name package_version package_arch host_arch
  local public_der public_key_text signing_key_digest derived_key_id
  local signature_file signature_round_trip message_file
  local available_kib available_bytes required_bytes

  cache_job_dir="${CACHE_JOBS_DIR}/${CURRENT_JOB_ID}"
  if [[ -e "${cache_job_dir}" || -L "${cache_job_dir}" ]]; then
    fail_job "A root-owned cache already exists for this update job."
    return 1
  fi
  available_kib="$(df -Pk "${CACHE_JOBS_DIR}" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if [[ ! "${available_kib}" =~ ^[0-9]+$ ]]; then
    fail_job "The update cache free space could not be determined."
    return 1
  fi
  available_bytes=$((available_kib * 1024))
  required_bytes=$((CURRENT_ARTIFACT_SIZE + MIN_FREE_BYTES))
  if (( available_bytes < required_bytes )); then
    fail_job "The update cache lacks space for the package and safety reserve."
    return 1
  fi

  install -d -m 0700 "${cache_job_dir}"
  cached_artifact="${cache_job_dir}/myscoutee.deb"
  if ! python3 "${SAFE_COPY_HELPER}" artifact \
    --staging-dir "${STAGING_DIR}" \
    --job-id "${CURRENT_JOB_ID}" \
    --destination "${cached_artifact}" \
    --expected-bytes "${CURRENT_ARTIFACT_SIZE}" \
    --max-bytes "${MAX_ARTIFACT_BYTES}" \
    --remove-source >> "${CURRENT_LOG_FILE}" 2>&1; then
    fail_job "The staged update artifact is missing, unsafe, changing, or has the wrong size."
    return 1
  fi

  actual_size="$(stat -c '%s' "${cached_artifact}")"
  [[ "${actual_size}" == "${CURRENT_ARTIFACT_SIZE}" ]] || {
    fail_job "The update artifact size does not match the signed manifest."
    return 1
  }
  actual_digest="sha256:$(sha256sum "${cached_artifact}" | awk '{ print $1 }')"
  [[ "${actual_digest}" == "${CURRENT_ARTIFACT_SHA256}" ]] || {
    fail_job "The update artifact digest does not match the signed manifest."
    return 1
  }

  if [[ ! -f "${RELEASE_PUBLIC_KEY}" || -L "${RELEASE_PUBLIC_KEY}" ]]; then
    fail_job "The pinned release-signing public key is unavailable."
    return 1
  fi
  public_der="${cache_job_dir}/release-public-key.der"
  if ! openssl pkey -pubin -in "${RELEASE_PUBLIC_KEY}" -outform DER \
    -out "${public_der}" >/dev/null 2>&1; then
    fail_job "The pinned release-signing public key is invalid."
    return 1
  fi
  if [[ "$(stat -c '%s' "${public_der}")" != "44" ]]; then
    fail_job "The pinned release-signing key is not Ed25519."
    return 1
  fi
  public_key_text="$(openssl pkey -pubin -in "${RELEASE_PUBLIC_KEY}" \
    -text -noout 2>/dev/null || true)"
  if [[ "${public_key_text}" != ED25519\ Public-Key:* ]]; then
    fail_job "The pinned release-signing key is not Ed25519."
    return 1
  fi
  signing_key_digest="$(sha256sum "${public_der}" | awk '{ print $1 }')"
  derived_key_id="pkey_${signing_key_digest:0:32}"
  [[ "${derived_key_id}" == "${CURRENT_PACKAGE_SIGNING_KEY_ID}" ]] || {
    fail_job "The package-signing key does not match the locally pinned key."
    return 1
  }

  signature_file="${cache_job_dir}/package-signature.bin"
  if ! printf '%s' "${CURRENT_PACKAGE_SIGNATURE}" \
    | base64 --decode > "${signature_file}" 2>/dev/null; then
    fail_job "The package signature is not canonical base64."
    return 1
  fi
  if [[ "$(stat -c '%s' "${signature_file}")" != "64" ]]; then
    fail_job "The package signature is not an Ed25519 signature."
    return 1
  fi
  signature_round_trip="$(base64 -w 0 "${signature_file}")"
  [[ "${signature_round_trip}" == "${CURRENT_PACKAGE_SIGNATURE}" ]] || {
    fail_job "The package signature is not canonical padded base64."
    return 1
  }

  message_file="${cache_job_dir}/package-signature-message"
  printf '%s\n' \
    "myscoutee-release-package-v1" \
    "${CURRENT_RELEASE_VERSION}" \
    "${CURRENT_CHANNEL}" \
    "${CURRENT_ARTIFACT_SIZE}" \
    "${CURRENT_ARTIFACT_SHA256}" > "${message_file}"
  if ! openssl pkeyutl -verify -pubin -inkey "${RELEASE_PUBLIC_KEY}" \
    -rawin -in "${message_file}" -sigfile "${signature_file}" \
    >/dev/null 2>&1; then
    fail_job "The detached package signature is invalid."
    return 1
  fi

  # Do not ask dpkg-deb or tar to parse attacker-controlled package structure
  # until the complete artifact digest has been authenticated by the pinned
  # release key.
  package_name="$(dpkg-deb -f "${cached_artifact}" Package 2>/dev/null || true)"
  package_version="$(dpkg-deb -f "${cached_artifact}" Version 2>/dev/null || true)"
  package_arch="$(dpkg-deb -f "${cached_artifact}" Architecture 2>/dev/null || true)"
  host_arch="$(dpkg --print-architecture)"
  [[ "${package_name}" == "${PACKAGE_NAME}" ]] || {
    fail_job "The signed artifact is not the MyScoutee package."
    return 1
  }
  [[ "${package_version}" == "$(debian_version "${CURRENT_RELEASE_VERSION}")" ]] || {
    fail_job "The Debian package version does not match the signed manifest."
    return 1
  }
  if [[ "${package_arch}" != "all" && "${package_arch}" != "${host_arch}" ]]; then
    fail_job "The Debian package architecture is incompatible with this host."
    return 1
  fi

  CURRENT_IMAGE_MANIFEST="${cache_job_dir}/image-manifest.json"
  if ! extract_image_manifest "${cached_artifact}" "${CURRENT_IMAGE_MANIFEST}" \
    || ! validate_image_manifest "${CURRENT_IMAGE_MANIFEST}"; then
    fail_job "The signed package lacks the required bundled-image manifest."
    return 1
  fi
  CURRENT_CACHED_ARTIFACT="${cached_artifact}"
}

# Display/signature versions use SemVer; dpkg orders prereleases with '~'.
debian_version() {
  printf '%s' "${1/-/\~}"
}

installed_version() {
  local version
  version="$(dpkg-query -W -f='${Version}' "${PACKAGE_NAME}" 2>/dev/null || true)"
  printf '%s' "${version/\~/-}"
}

# Only fixed installer milestones affect progress; arbitrary log lines stay logs.
# The command's exit status is retained through pipefail. No marker can report success.
run_with_progress() {
  "$@" 2>&1 | while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line" >> "${CURRENT_LOG_FILE}"
    case "$line" in
      '[myscoutee-update-phase] CONFIGURING_PACKAGE') write_status CONFIGURING_PACKAGE 86 "Configuring the package." ;;
      '[myscoutee-update-phase] LOADING_IMAGES') write_status LOADING_IMAGES 87 "Loading packaged images." ;;
      '[myscoutee-update-phase] VERIFYING_IMAGES') write_status VERIFYING_IMAGES 90 "Verifying packaged images." ;;
      '[myscoutee-update-phase] PREPARING_DATA') write_status PREPARING_DATA 93 "Preparing package-owned data." ;;
      '[myscoutee-update-phase] STARTING_SERVICES') write_status STARTING_SERVICES 94 "Starting services." ;;
      '[myscoutee-update-phase] WAITING_FOR_HEALTH') write_status WAITING_FOR_HEALTH 96 "Waiting for application health." ;;
      '[myscoutee-update-phase] SWITCHING_INGRESS') write_status SWITCHING_INGRESS 98 "Switching the web server." ;;
    esac
  done
}

install_package() {
  local cached_artifact="$1"
  local installed_after

  local -a downgrade_options=()
  [[ -z "$CURRENT_ROLLBACK_JOB" ]] || downgrade_options=(--allow-downgrades)
  if ! run_with_progress env DEBIAN_FRONTEND=noninteractive \
    apt-get -o Dpkg::Use-Pty=0 install -y "${downgrade_options[@]}" "${cached_artifact}"; then
    recovery_required "Package installation may be partial. Inspect the install log before retrying; preserve existing deployment data."
    return 1
  fi
  installed_after="$(installed_version)"
  if [[ "${installed_after}" != "${CURRENT_RELEASE_VERSION}" ]]; then
    recovery_required "The package manager did not activate the requested version; automatic retry is unsafe."
    return 1
  fi
  CURRENT_VERSION="${installed_after}"
  if [[ ! -f "${INSTALLED_MANIFEST_PATH}" || -L "${INSTALLED_MANIFEST_PATH}" ]] \
    || ! cmp -s "${CURRENT_IMAGE_MANIFEST}" "${INSTALLED_MANIFEST_PATH}"; then
    recovery_required "The installed image manifest does not match the verified package."
    return 1
  fi
}

verify_running_release() {
  local manifest="$1"
  local container reference expected_content_fingerprint configured_reference
  local running_image_id actual_content_fingerprint
  local -a runtime_images=()

  validate_image_manifest "${manifest}" || return 1
  mapfile -t runtime_images < <(
    jq -r '.images[] | select(.container != null)
      | [.container, .reference, .contentFingerprint] | @tsv' "${manifest}"
  )
  # The version-specific service set was validated above; old releases have
  # five runtime images, releases from 1.3.0 have six including MCP.
  [[ "${#runtime_images[@]}" == "$(jq '[.images[] | select(.container != null)] | length' "$manifest")" ]] || return 1
  for image in "${runtime_images[@]}"; do
    IFS=$'\t' read -r \
      container reference expected_content_fingerprint <<< "${image}"
    configured_reference="$(docker inspect --format '{{.Config.Image}}' \
      "${container}" 2>/dev/null || true)"
    running_image_id="$(docker inspect --format '{{.Image}}' \
      "${container}" 2>/dev/null || true)"
    actual_content_fingerprint="$(
      "${IMAGE_CONTENT_FINGERPRINT_HELPER}" \
        docker "${running_image_id}" 2>/dev/null || true
    )"
    [[ "${configured_reference}" == "${reference}" \
      && "${actual_content_fingerprint}" \
        == "${expected_content_fingerprint}" ]] || return 1
    [[ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
      "${container}" 2>/dev/null || true)" == "healthy" ]] || return 1
  done
  systemctl is-active --quiet "${RELEASE_PROJECT_NAME}.service"
}

restart_and_verify_release() {
  local manifest="$1"
  local deadline

  if ! run_with_progress "${RESTART_HELPER}"; then
    return 1
  fi
  deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if verify_running_release "${manifest}"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

reconcile_existing_job() {
  local phase installed

  phase="$(current_phase)"
  if is_terminal_phase "${phase}"; then
    [[ "${phase}" == "COMPLETED" ]]
    return
  fi
  installed="$(installed_version)"
  CURRENT_VERSION="${installed}"
  if [[ "${installed}" == "${CURRENT_RELEASE_VERSION}" \
    && -f "${INSTALLED_MANIFEST_PATH}" \
    && ! -L "${INSTALLED_MANIFEST_PATH}" ]] \
    && validate_image_manifest "${INSTALLED_MANIFEST_PATH}" \
    && restart_and_verify_release "${INSTALLED_MANIFEST_PATH}"; then
    record_completed_package
    write_status "COMPLETED" 100 \
      "Recovered after interruption: the exact requested package and images are active and healthy."
    log_line "Recovered completed update ${CURRENT_JOB_ID} after interruption."
    return 0
  fi
  recovery_required \
    "An earlier update attempt was interrupted and cannot be retried automatically. Inspect the install log before recovery; preserve existing deployment data."
}

# Only root-owned receipts can authorize a downgrade. A browser request cannot
# nominate an arbitrary old version, and matching a version alone is insufficient.
read_root_receipt() {
  local receipt="$1"
  [[ -f "$receipt" && ! -L "$receipt" && "$(stat -c %u "$receipt")" == "$WORKER_USER_ID" ]] || return 1
  (( (8#$(stat -c %a "$receipt") & 8#022) == 0 )) || return 1
  [[ $(stat -c %s "$receipt") -le 4096 ]] || return 1
  cat "$receipt"
}

write_root_receipt() {
  local destination="$1" temporary
  temporary="$(mktemp "${RUNTIME_DIR}/.receipt.XXXXXX")"
  cat > "$temporary"
  chown "+${WORKER_USER_ID}:+${API_GROUP_ID}" "$temporary"
  chmod 0640 "$temporary"
  fsync_path "$temporary"
  mv -T "$temporary" "$destination"
  fsync_path "$RUNTIME_DIR"
}

validate_rollback_target() {
  local receipt
  receipt="$(read_root_receipt "$RUNTIME_DIR/recovery.json")" || return 1
  jq -e --arg job "$CURRENT_ROLLBACK_JOB" --arg current "$CURRENT_VERSION" \
    --arg version "$CURRENT_RELEASE_VERSION" --arg hash "$CURRENT_ARTIFACT_SHA256" \
    '.jobId == $job and .fromVersion == $current and .targetVersion == $version and .artifactSha256 == $hash' \
    <<< "$receipt" >/dev/null
}

retain_recovery_point() {
  local receipt
  # No recorded identity means no rollback claim for this legacy installation.
  if receipt="$(read_root_receipt "$RUNTIME_DIR/installed-package.json")" && \
    jq -e --arg current "$CURRENT_VERSION" '.version == $current and (.artifactSha256 | test("^sha256:[0-9a-f]{64}$"))' <<< "$receipt" >/dev/null; then
    jq --arg job "$CURRENT_JOB_ID" --arg target "$CURRENT_RELEASE_VERSION" \
      '{jobId:$job,fromVersion:$target,targetVersion:.version,artifactSha256:.artifactSha256}' \
      <<< "$receipt" | write_root_receipt "$RUNTIME_DIR/recovery.json"
  else
    [[ ! -e "$RUNTIME_DIR/recovery.json" && ! -L "$RUNTIME_DIR/recovery.json" ]] || unlink "$RUNTIME_DIR/recovery.json"
  fi
}

record_completed_package() {
  jq -n --arg version "$CURRENT_RELEASE_VERSION" --arg hash "$CURRENT_ARTIFACT_SHA256" \
    '{version:$version,artifactSha256:$hash}' | write_root_receipt "$RUNTIME_DIR/installed-package.json"
  if [[ -n "$CURRENT_ROLLBACK_JOB" ]]; then
    [[ ! -e "$RUNTIME_DIR/recovery.json" && ! -L "$RUNTIME_DIR/recovery.json" ]] || unlink "$RUNTIME_DIR/recovery.json"
    fsync_path "$RUNTIME_DIR"
  fi
}

process_job() {
  JOB_CONTEXT_STATE=""
  if ! prepare_job_context; then
    return 2
  fi
  CURRENT_VERSION="$(installed_version)"

  if [[ "${JOB_CONTEXT_STATE}" != "new" ]]; then
    reconcile_existing_job
    return
  fi
  if [[ "${UPDATE_ENABLED}" != "true" ]]; then
    fail_job "The host update execution gate is disabled."
    return 1
  fi
  if [[ -z "${CURRENT_VERSION}" ]]; then
    fail_job "MyScoutee is not installed through the Debian package."
    return 1
  fi
  if [[ -n "$CURRENT_ROLLBACK_JOB" ]]; then
    if ! validate_rollback_target; then
      fail_job "The requested rollback does not match the retained previous package identity."
      return 1
    fi
  elif ! dpkg --compare-versions "$(debian_version "${CURRENT_RELEASE_VERSION}")" gt "$(debian_version "${CURRENT_VERSION}")"; then
    fail_job "The requested release is not newer than the installed version."
    return 1
  fi

  log_line "Accepted update ${CURRENT_JOB_ID} from ${CURRENT_VERSION} to ${CURRENT_RELEASE_VERSION}."
  write_status "VERIFYING" 72 \
    "Verifying the staged Debian package, release signature, and bundled-image manifest."
  if ! verify_and_cache_artifact; then
    return 1
  fi

  [[ -n "$CURRENT_ROLLBACK_JOB" ]] || retain_recovery_point
  write_status "INSTALLING" 85 "Installing the verified Debian package."
  if ! install_package "${CURRENT_CACHED_ARTIFACT}"; then
    return 1
  fi

  write_status "RESTARTING" 92 \
    "Restarting and verifying the exact packaged Docker image identities."
  if ! restart_and_verify_release "${CURRENT_IMAGE_MANIFEST}"; then
    recovery_required \
      "The requested package is installed, but its exact packaged images did not become healthy. Inspect the install log for recovery; preserve existing deployment data."
    return 1
  fi

  CURRENT_VERSION="${CURRENT_RELEASE_VERSION}"
  record_completed_package
  write_status "COMPLETED" 100 \
    "The verified package and exact bundled images are installed and healthy."
  log_line "Completed update ${CURRENT_JOB_ID}."
}

claim_request_entry() {
  local request_entry="$1"
  local claim_dir

  claim_dir="$(mktemp -d "${PROCESSING_DIR}/claim.XXXXXX")"
  chmod 0700 "${claim_dir}"
  if ! mv -- "${request_entry}" "${claim_dir}/request"; then
    rmdir "${claim_dir}" 2>/dev/null || true
    return 1
  fi
  printf '%s\n' "$(basename -- "${request_entry}")" > "${claim_dir}/original-name"
  chmod 0600 "${claim_dir}/original-name"
  fsync_path "${claim_dir}"
  fsync_path "${REQUEST_DIR}"
  fsync_path "${PROCESSING_DIR}"
  printf '%s' "${claim_dir}"
}

quarantine_claim() {
  local claim_dir="$1"
  local reason="$2"
  local destination

  logger -t myscoutee-update-worker -- "Rejected update input: ${reason}" \
    >/dev/null 2>&1 || true
  if [[ -d "${claim_dir}" && ! -L "${claim_dir}" ]]; then
    printf '%s\n' "${reason}" > "${claim_dir}/rejection.txt"
    chmod 0600 "${claim_dir}/rejection.txt"
  fi
  if [[ -e "${claim_dir}" || -L "${claim_dir}" ]]; then
    destination="${REJECTED_DIR}/$(date -u '+%Y%m%dT%H%M%SZ')-$(basename -- "${claim_dir}")"
    mv -- "${claim_dir}" "${destination}"
    fsync_path "${REJECTED_DIR}"
    fsync_path "${PROCESSING_DIR}"
  fi
}

archive_claim() {
  local claim_dir="$1"
  local phase="$2"
  local target_dir archive_name

  if [[ "${phase}" == "COMPLETED" ]]; then
    target_dir="${COMPLETED_DIR}"
  else
    target_dir="${FAILED_DIR}"
  fi
  archive_name="${CURRENT_JOB_ID}-$(date -u '+%Y%m%dT%H%M%SZ')-$(basename -- "${claim_dir}").json"
  mv -- "${claim_dir}/request.snapshot" "${target_dir}/${archive_name}"
  chmod 0600 "${target_dir}/${archive_name}"
  fsync_path "${target_dir}"
  rm -rf -- "${claim_dir}"
  fsync_path "${PROCESSING_DIR}"
}

process_claim() {
  local claim_dir="$1"
  local request_snapshot phase result

  CURRENT_CLAIM_DIR="${claim_dir}"
  if [[ ! -d "${claim_dir}" || -L "${claim_dir}" \
    || ! -e "${claim_dir}/request" ]]; then
    quarantine_claim "${claim_dir}" "the durable claim is malformed"
    return 1
  fi
  request_snapshot="${claim_dir}/request.snapshot"
  if ! python3 "${SAFE_COPY_HELPER}" request \
    --source-dir "${claim_dir}" \
    --name request \
    --destination "${request_snapshot}" \
    --max-bytes "${MAX_REQUEST_BYTES}" >/dev/null 2>&1; then
    quarantine_claim "${claim_dir}" \
      "the request is not a stable regular file or exceeds the size limit"
    return 1
  fi
  if ! read_request "${request_snapshot}"; then
    quarantine_claim "${claim_dir}" "the request JSON or fields are invalid"
    return 1
  fi

  result=0
  process_job || result=$?
  if (( result == 2 )); then
    quarantine_claim "${claim_dir}" \
      "the job ID conflicts with different or unsafe durable state"
    return 1
  fi
  phase="$(current_phase)"
  if ! is_terminal_phase "${phase}"; then
    recovery_required \
      "The privileged worker stopped unexpectedly after accepting this job; automatic retry is unsafe." \
      || true
    phase="RECOVERY_REQUIRED"
    result=1
  fi
  archive_claim "${claim_dir}" "${phase}"
  (( result == 0 ))
}

prune_cache() {
  local index directory base
  local -a cache_entries=()

  mapfile -t cache_entries < <(
    find "${CACHE_JOBS_DIR}" -mindepth 1 -maxdepth 1 -type d \
      -name 'upd_[0-9a-f]*' -printf '%T@ %p\n' \
      | sort -rn | awk '{ print $2 }'
  )
  for ((index = CACHE_RETENTION_JOBS; index < ${#cache_entries[@]}; index++)); do
    directory="${cache_entries[index]}"
    base="$(basename -- "${directory}")"
    [[ "${base}" =~ ^upd_[0-9a-f]{32}$ \
      && "${directory}" == "${CACHE_JOBS_DIR}/${base}" ]] || continue
    rm -rf -- "${directory}"
  done
  fsync_path "${CACHE_JOBS_DIR}"
}

main() {
  local entry claim_dir
  local -a claims=()
  local -a entries=()

  [[ "$(id -u)" == "0" ]] || {
    echo "The MyScoutee update worker must run as root." >&2
    exit 1
  }
  require_runtime
  prepare_directories

  shopt -s nullglob dotglob
  claims=("${PROCESSING_DIR}"/*)
  shopt -u dotglob
  for claim_dir in "${claims[@]}"; do
    process_claim "${claim_dir}" || true
  done

  shopt -s nullglob dotglob
  entries=("${REQUEST_DIR}"/*)
  shopt -u dotglob
  for entry in "${entries[@]}"; do
    if claim_dir="$(claim_request_entry "${entry}")"; then
      process_claim "${claim_dir}" || true
    fi
  done
  prune_cache
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
