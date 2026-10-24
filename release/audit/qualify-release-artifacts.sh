#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:?Select a project with the packaging CLI.}"
source "${SCRIPT_DIR}/../lib/release-config.sh"
release_config_load "${REPO_ROOT}"
source "${SCRIPT_DIR}/../lib/release-project.sh"
release_project_load "${REPO_ROOT}/config/packaging" "$(id -u)"
registry_service="$(release_config_value .qualification.registryService)"
registry_source="${REPO_ROOT}/$(release_config_value .qualification.registrySource)"
registry_contract="$(jq -ce --arg service "$registry_service" '.qualification.imageContracts[$service]' <<< "$RELEASE_SETTINGS")"
IMAGE_FINGERPRINT_HELPER="${SCRIPT_DIR}/../lib/image-content-fingerprint.sh"

CANDIDATE_DEB="${MYSCOUTEE_CANDIDATE_DEB:-${1:-}}"
OLDEST_SUPPORTED_DEB="${MYSCOUTEE_OLDEST_SUPPORTED_DEB:-${2:-}}"
REGISTRY_IMAGE="${MYSCOUTEE_REGISTRY_IMAGE:-${3:-}}"
EVIDENCE_DIR="${MYSCOUTEE_QUALIFICATION_EVIDENCE_DIR:-}"

usage() {
  cat >&2 <<'EOF'
Usage:
  MYSCOUTEE_QUALIFICATION_EVIDENCE_DIR=/absolute/output/directory \
    qualify-release-artifacts.sh \
      /absolute/myscoutee_<candidate>_<arch>.deb \
      /absolute/myscoutee_<oldest-supported>_<arch>.deb \
      myscoutee-registry:<candidate>-prod

This command performs read-only candidate-artifact checks and writes a
machine-readable evidence manifest. It does not install, upgrade, restore, or
start any service. Those host-changing release drills remain separate.
EOF
  exit 2
}

[[ -n "${CANDIDATE_DEB}" && -n "${OLDEST_SUPPORTED_DEB}" \
  && -n "${REGISTRY_IMAGE}" && -n "${EVIDENCE_DIR}" ]] || usage
[[ "${CANDIDATE_DEB}" == /* && "${OLDEST_SUPPORTED_DEB}" == /* \
  && "${EVIDENCE_DIR}" == /* ]] || {
  echo "Candidate, oldest-supported package, and evidence paths must be absolute." >&2
  exit 2
}
[[ -f "${CANDIDATE_DEB}" && ! -L "${CANDIDATE_DEB}" ]] || {
  echo "Candidate Debian package is missing or is a symbolic link." >&2
  exit 2
}
[[ -f "${OLDEST_SUPPORTED_DEB}" && ! -L "${OLDEST_SUPPORTED_DEB}" ]] || {
  echo "Oldest-supported Debian package is missing or is a symbolic link." >&2
  exit 2
}
[[ "${CANDIDATE_DEB}" != "${OLDEST_SUPPORTED_DEB}" ]] || {
  echo "Candidate and oldest-supported package paths must differ." >&2
  exit 2
}
if [[ -e "${EVIDENCE_DIR}" && (! -d "${EVIDENCE_DIR}" || -L "${EVIDENCE_DIR}") ]]; then
  echo "Evidence path must be a real directory, not a file or symbolic link." >&2
  exit 2
fi

for command_name in docker dpkg dpkg-deb jq sha256sum stat tar uname; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Release-artifact qualification requires ${command_name}." >&2
    exit 2
  }
done

candidate_package="$(dpkg-deb -f "${CANDIDATE_DEB}" Package)"
candidate_version="$(dpkg-deb -f "${CANDIDATE_DEB}" Version)"
candidate_architecture="$(dpkg-deb -f "${CANDIDATE_DEB}" Architecture)"
oldest_package="$(dpkg-deb -f "${OLDEST_SUPPORTED_DEB}" Package)"
oldest_version="$(dpkg-deb -f "${OLDEST_SUPPORTED_DEB}" Version)"
oldest_architecture="$(dpkg-deb -f "${OLDEST_SUPPORTED_DEB}" Architecture)"

[[ "${candidate_package}" == "$RELEASE_PROJECT_NAME" && "${oldest_package}" == "$RELEASE_PROJECT_NAME" ]] || {
  echo "Both artifacts must be MyScoutee Debian packages." >&2
  exit 1
}
[[ "${candidate_architecture}" == "${oldest_architecture}" ]] || {
  echo "Candidate and oldest-supported package architectures differ." >&2
  exit 1
}
dpkg --validate-version "${candidate_version}" >/dev/null 2>&1
dpkg --validate-version "${oldest_version}" >/dev/null 2>&1
dpkg --compare-versions "${candidate_version}" gt "${oldest_version}" || {
  echo "Candidate version must be newer than the oldest-supported version." >&2
  exit 1
}
[[ "${candidate_version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(~qa\.[1-9][0-9]*)?$ ]] || {
  echo "Candidate package version must be a SemVer core or QA prerelease." >&2
  exit 1
}

candidate_version="${candidate_version//\~/-}"
oldest_version="${oldest_version//\~/-}"
inventory="$(jq -c --arg version "$candidate_version" '.images | map(. + {reference:(.repository + ":" + $version + "-" + .tagSuffix)})' "$RELEASE_PROJECT_POLICY")"
expected_registry_image="$(jq -er --arg service "$registry_service" '.[] | select(.service == $service) | .reference' <<< "$inventory")"
[[ "${REGISTRY_IMAGE}" == "${expected_registry_image}" ]] || {
  echo "Registry image must use the candidate-derived tag ${expected_registry_image}." >&2
  exit 1
}
docker image inspect "${REGISTRY_IMAGE}" >/dev/null

registry_user="$(docker image inspect --format '{{.Config.User}}' "${REGISTRY_IMAGE}")"
registry_entrypoint="$(
  docker image inspect --format '{{json .Config.Entrypoint}}' "${REGISTRY_IMAGE}"
)"
registry_ports="$(
  docker image inspect --format '{{json .Config.ExposedPorts}}' "${REGISTRY_IMAGE}"
)"
registry_os="$(docker image inspect --format '{{.Os}}' "${REGISTRY_IMAGE}")"
registry_architecture="$(docker image inspect --format '{{.Architecture}}' "${REGISTRY_IMAGE}")"
registry_image_id="$(docker image inspect --format '{{.Id}}' "${REGISTRY_IMAGE}")"
registry_content_fingerprint="$(
  bash "${IMAGE_FINGERPRINT_HELPER}" docker "${REGISTRY_IMAGE}"
)"
registry_repo_digests="$(
  docker image inspect --format '{{json .RepoDigests}}' "${REGISTRY_IMAGE}"
)"

[[ "${registry_user}" == "$(jq -r .user <<< "$registry_contract")" ]] || {
  echo "Registry image does not run as numeric user 65532:65532." >&2
  exit 1
}
[[ "${registry_entrypoint}" == "$(jq -c .entrypoint <<< "$registry_contract")" ]] || {
  echo "Registry image entrypoint is not the scratch-runtime registry binary." >&2
  exit 1
}
jq -e --argjson contract "$registry_contract" 'keys == $contract.ports' <<< "${registry_ports}" >/dev/null || {
  echo "Registry image must expose only container port 8080." >&2
  exit 1
}
[[ "${registry_os}" == "$(release_config_value .qualification.platform)" ]] || {
  echo "Registry candidate image is not a Linux image." >&2
  exit 1
}
[[ "${registry_architecture}" == "${candidate_architecture}" ]] || {
  echo "Registry image and candidate Debian architectures differ." >&2
  exit 1
}

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/myscoutee-release-artifacts.XXXXXX")"
cleanup() {
  rm -rf -- "${work_dir}"
}
trap cleanup EXIT

candidate_root="${work_dir}/candidate"
install -d "${candidate_root}"
dpkg-deb -x "${CANDIDATE_DEB}" "${candidate_root}"

bash "${SCRIPT_DIR}/audit-package-credentials.sh" "${candidate_root}"

packaged_version_file="${candidate_root}${RELEASE_PROJECT_ROOT}/packaging/VERSION"
[[ -f "${packaged_version_file}" ]] || {
  echo "Candidate package omits the installed VERSION marker." >&2
  exit 1
}
[[ "$(tr -d '\r\n' < "${packaged_version_file}")" == "${candidate_version}" ]] || {
  echo "Candidate control version and installed VERSION marker differ." >&2
  exit 1
}

candidate_image_manifest="${candidate_root}${RELEASE_PROJECT_ROOT}/packaging/IMAGE-MANIFEST.json"
[[ -f "${candidate_image_manifest}" && ! -L "${candidate_image_manifest}" ]] || {
  echo "Candidate package omits the bundled-image manifest." >&2
  exit 1
}
jq -e \
  --arg version "${candidate_version}" --argjson inventory "$inventory" \
  '
    .schemaVersion == 1
    and .releaseVersion == $version
    and .bundled == true
    and (.images | length) == ($inventory | length)
    and ([.images[].service] | sort) == ([$inventory[].service] | sort)
    and all(.images[];
      (.imageId | test("^sha256:[0-9a-f]{64}$"))
      and (.contentFingerprint | test("^sha256:[0-9a-f]{64}$"))
      and (.reference | type == "string")
    )
  ' "${candidate_image_manifest}" >/dev/null || {
  echo "Candidate bundled-image manifest is invalid or incomplete." >&2
  exit 1
}

managed_images_jsonl="${work_dir}/managed-images.jsonl"
: > "${managed_images_jsonl}"
while IFS='|' read -r service expected_reference archive_name; do
  [[ -n "${service}" ]] || continue
  image_archive="${candidate_root}${RELEASE_PROJECT_ROOT}/images/${archive_name}.tar"
  [[ -f "${image_archive}" && ! -L "${image_archive}" ]] || {
    echo "Candidate package omits managed image archive ${archive_name}.tar." >&2
    exit 1
  }
  manifest_item="$(
    jq -ce \
      --arg service "${service}" \
      --arg reference "${expected_reference}" \
      '
        [.images[]
          | select(.service == $service and .reference == $reference)]
        | if length == 1 then .[0] else error("managed image mismatch") end
      ' "${candidate_image_manifest}"
  )" || {
    echo "Candidate manifest does not bind ${service} to ${expected_reference}." >&2
    exit 1
  }
  archive_manifest="$(tar -xOf "${image_archive}" manifest.json)" || {
    echo "Managed image archive ${archive_name}.tar has no Docker manifest." >&2
    exit 1
  }
  jq -e \
    --arg reference "${expected_reference}" \
    '
      length == 1
      and (.[0].RepoTags | index($reference)) != null
      and (.[0].Config | type == "string")
    ' <<< "${archive_manifest}" >/dev/null || {
    echo "Managed image archive ${archive_name}.tar has an unexpected tag set." >&2
    exit 1
  }
  config_path="$(jq -er '.[0].Config' <<< "${archive_manifest}")"
  [[ "${config_path}" =~ ^([0-9a-f]{64}\.json|blobs/sha256/[0-9a-f]{64})$ ]] || {
    echo "Managed image archive ${archive_name}.tar has an unsafe config path." >&2
    exit 1
  }
  image_config="$(tar -xOf "${image_archive}" "${config_path}")" || {
    echo "Managed image archive ${archive_name}.tar omits its image config." >&2
    exit 1
  }
  config_digest="sha256:$(
    tar -xOf "${image_archive}" "${config_path}" | sha256sum | awk '{print $1}'
  )"
  manifest_image_id="$(jq -er '.imageId' <<< "${manifest_item}")"
  [[ "${config_digest}" == "${manifest_image_id}" ]] || {
    echo "Managed image archive ${archive_name}.tar differs from IMAGE-MANIFEST.json." >&2
    exit 1
  }
  manifest_content_fingerprint="$(
    jq -er '.contentFingerprint' <<< "${manifest_item}"
  )"
  archive_content_fingerprint="$(
    printf '%s\n' "${image_config}" \
      | bash "${IMAGE_FINGERPRINT_HELPER}" config -
  )"
  [[ "${archive_content_fingerprint}" == "${manifest_content_fingerprint}" ]] || {
    echo "Managed image archive ${archive_name}.tar content fingerprint differs from IMAGE-MANIFEST.json." >&2
    exit 1
  }
  image_os="$(jq -er '.os' <<< "${image_config}")"
  image_architecture="$(jq -er '.architecture' <<< "${image_config}")"
  [[ "${image_os}" == "$(release_config_value .qualification.platform)" \
    && "${image_architecture}" == "${candidate_architecture}" ]] || {
    echo "Managed image ${expected_reference} does not match the candidate platform." >&2
    exit 1
  }
  if jq -e --arg service "$service" '.qualification.archiveContractServices | index($service) != null' <<< "$RELEASE_SETTINGS" >/dev/null; then
    contract="$(jq -ce --arg service "$service" '.qualification.imageContracts[$service]' <<< "$RELEASE_SETTINGS")"
    jq -e --argjson contract "$contract" '
      .config.User == $contract.user
      and .config.Entrypoint == $contract.entrypoint
      and ((.config.ExposedPorts | keys) == $contract.ports)
      and .config.WorkingDir == $contract.workingDirectory
    ' <<< "${image_config}" >/dev/null || {
      echo "Payment simulator image does not match its unprivileged scratch-runtime contract." >&2
      exit 1
    }
  fi
  archive_sha256="$(sha256sum "${image_archive}" | awk '{print $1}')"
  archive_size="$(stat -c '%s' "${image_archive}")"
  jq -nc \
    --arg service "${service}" \
    --arg reference "${expected_reference}" \
    --arg imageID "${manifest_image_id}" \
    --arg contentFingerprint "${manifest_content_fingerprint}" \
    --arg archivePath "${RELEASE_PROJECT_ROOT#/}/images/${archive_name}.tar" \
    --arg archiveSha256 "sha256:${archive_sha256}" \
    --argjson archiveSize "${archive_size}" \
    --arg os "${image_os}" \
    --arg architecture "${image_architecture}" \
    '{
      service: $service,
      reference: $reference,
      imageID: $imageID,
      contentFingerprint: $contentFingerprint,
      archivePath: $archivePath,
      archiveSha256: $archiveSha256,
      archiveSizeBytes: $archiveSize,
      os: $os,
      architecture: $architecture
    }' >> "${managed_images_jsonl}"
done < <(jq -r '.[] | [.service,.reference,(.reference | sub(":"; "-"))] | join("|")' <<< "$inventory")
managed_images_json="${work_dir}/managed-images.json"
jq -s '.' "${managed_images_jsonl}" > "${managed_images_json}"

packaged_registry_content_fingerprint="$(
  jq -er --arg service "$registry_service" '
    .images[]
    | select(.service == $service)
    | .contentFingerprint
  ' "${candidate_image_manifest}"
)"
[[ "${packaged_registry_content_fingerprint}" == "${registry_content_fingerprint}" ]] || {
  echo "Inspected registry image differs from the image bundled in the candidate." >&2
  exit 1
}

candidate_compose="${candidate_root}${RELEASE_PROJECT_ROOT}/server/docker-compose-prod.yml"
[[ -f "${candidate_compose}" ]] || {
  echo "Candidate package omits the production Compose definition." >&2
  exit 1
}
candidate_environment="${candidate_root}${RELEASE_PROJECT_ROOT}/packaging/templates/${RELEASE_PROJECT_NAME}.env"
[[ -f "${candidate_environment}" ]] || {
  echo "Candidate package omits the production environment template." >&2
  exit 1
}

assert_packaged_image_binding() {
  local variable_name="$1"
  local expected_reference="$2"

  grep -Fqx "${variable_name}=${expected_reference}" "${candidate_environment}" || {
    echo "Candidate environment does not bind ${variable_name} to ${expected_reference}." >&2
    exit 1
  }
  grep -Fq "image: \${${variable_name}:-" "${candidate_compose}" || {
    echo "Candidate Compose does not consume ${variable_name}." >&2
    exit 1
  }
}

while IFS=$'\t' read -r environment reference; do
  assert_packaged_image_binding "$environment" "$reference"
done < <(jq -r '.[] | select(.tagSuffix == "prod") | [.environment,.reference] | @tsv' <<< "$inventory")
while IFS=$'\t' read -r compose_service service_label; do
  if awk -v service="$compose_service" '
      $0 ~ "^  " service ":" { in_service = 1; next }
      /^  [[:alnum:]_-]+:/ { in_service = 0 }
      in_service && /^[[:space:]]+ports:/ { found = 1 }
      END { exit !found }
    ' "${candidate_compose}"; then
    echo "Packaged ${service_label} unexpectedly publishes a host port." >&2
    exit 1
  fi
done < <(release_config_value '.qualification.internalComposeServices[] | [.service,.label] | @tsv')

candidate_sha256="$(sha256sum "${CANDIDATE_DEB}" | awk '{print $1}')"
oldest_sha256="$(sha256sum "${OLDEST_SUPPORTED_DEB}" | awk '{print $1}')"
candidate_size="$(stat -c '%s' "${CANDIDATE_DEB}")"
oldest_size="$(stat -c '%s' "${OLDEST_SUPPORTED_DEB}")"
source_commit="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || true)"
registry_source_commit="$(
  git -C "${registry_source}" rev-parse HEAD 2>/dev/null || true
)"
backend_dirty="$(
  if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain 2>/dev/null || true)" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
)"
registry_dirty="$(
  if [[ -n "$(
    git -C "${registry_source}" status --porcelain 2>/dev/null || true
  )" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
)"

install -d -m 0750 "${EVIDENCE_DIR}"
evidence_path="${EVIDENCE_DIR}/release-artifact-evidence.json"
evidence_tmp="$(mktemp "${EVIDENCE_DIR}/.release-artifact-evidence.XXXXXX")"
trap 'rm -f -- "${evidence_tmp}"; cleanup' EXIT

jq -n \
  --slurpfile managedImages "${managed_images_json}" \
  --arg generatedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg sourceCommit "${source_commit}" \
  --arg registrySourceCommit "${registry_source_commit}" \
  --argjson backendDirty "${backend_dirty}" \
  --argjson registryDirty "${registry_dirty}" \
  --arg host "$(uname -srvmo)" \
  --arg candidatePath "${CANDIDATE_DEB}" \
  --arg candidateVersion "${candidate_version}" \
  --arg candidateArchitecture "${candidate_architecture}" \
  --arg candidateSha256 "sha256:${candidate_sha256}" \
  --argjson candidateSize "${candidate_size}" \
  --arg oldestPath "${OLDEST_SUPPORTED_DEB}" \
  --arg oldestVersion "${oldest_version}" \
  --arg oldestArchitecture "${oldest_architecture}" \
  --arg oldestSha256 "sha256:${oldest_sha256}" \
  --argjson oldestSize "${oldest_size}" \
  --arg registryImage "${REGISTRY_IMAGE}" \
  --arg registryImageID "${registry_image_id}" \
  --arg registryContentFingerprint "${registry_content_fingerprint}" \
  --argjson registryRepoDigests "${registry_repo_digests}" \
  --arg registryOS "${registry_os}" \
  --arg registryArchitecture "${registry_architecture}" \
  --argjson registryContract "$registry_contract" \
  '{
    schemaVersion: 1,
    generatedAt: $generatedAt,
    source: {
      backendCommit: $sourceCommit,
      backendCheckoutDirty: $backendDirty,
      registryCommit: $registrySourceCommit,
      registryCheckoutDirty: $registryDirty,
      binding: "checkout context only; package/image hashes are authoritative"
    },
    host: $host,
    artifacts: {
      candidatePackage: {
        path: $candidatePath,
        version: $candidateVersion,
        architecture: $candidateArchitecture,
        sha256: $candidateSha256,
        sizeBytes: $candidateSize
      },
      oldestSupportedPackage: {
        path: $oldestPath,
        version: $oldestVersion,
        architecture: $oldestArchitecture,
        sha256: $oldestSha256,
        sizeBytes: $oldestSize
      },
      managedImages: $managedImages[0],
      registryImage: {
        reference: $registryImage,
        imageID: $registryImageID,
        contentFingerprint: $registryContentFingerprint,
        repoDigests: $registryRepoDigests,
        os: $registryOS,
        architecture: $registryArchitecture,
        user: $registryContract.user,
        entrypoint: $registryContract.entrypoint,
        exposedPorts: $registryContract.ports
      }
    },
    automatedChecks: {
      packageIdentityAndVersionOrdering: "PASS",
      packageCredentialAudit: "PASS",
      packageVersionMarker: "PASS",
      completeBundledImageBinding: "PASS",
      packagedExploreRegistryIsolation: "PASS",
      registryImageRuntimeContract: "PASS"
    },
    externalDrills: {
      exactArtifactJavaGoRail: "OPEN",
      hostInstallRestartAndPowerLoss: "OPEN",
      cleanHostBackupRestore: "OPEN",
      oldestSupportedUpgradeAndRollback: "OPEN",
      publicTLSMultiRegistryIsolation: "OPEN",
      sustainedAndBurstLoad: "OPEN",
      independentSecurityReview: "OPEN"
    }
  }' > "${evidence_tmp}"
chmod 0640 "${evidence_tmp}"
mv -f -- "${evidence_tmp}" "${evidence_path}"
trap cleanup EXIT

echo "Release-artifact preflight passed."
echo "Evidence: ${evidence_path}"
echo "Host-changing and external Phase 9 drills remain OPEN in the evidence manifest."
