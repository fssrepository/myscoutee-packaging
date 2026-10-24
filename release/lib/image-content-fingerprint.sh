#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  image-content-fingerprint.sh docker IMAGE
  image-content-fingerprint.sh config FILE|-

Prints a storage-backend-independent SHA-256 fingerprint for a Docker image.
The config mode accepts the raw OCI/Docker image configuration JSON.
EOF
  exit 2
}

for command_name in jq sha256sum; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Image fingerprinting requires ${command_name}." >&2
    exit 2
  }
done

canonicalize_docker_inspect() {
  jq -ceS '
    if type == "array" and length == 1 and (.[0] | type) == "object"
    then .[0]
    else error("expected one Docker image inspect object")
    end
    | {
        schemaVersion: 1,
        architecture: (.Architecture // ""),
        os: (.Os // ""),
        config: {
          user: (.Config.User // ""),
          env: (.Config.Env // []),
          entrypoint: (.Config.Entrypoint // []),
          cmd: (.Config.Cmd // []),
          workingDir: (.Config.WorkingDir // ""),
          labels: (.Config.Labels // {}),
          exposedPorts: (.Config.ExposedPorts // {}),
          volumes: (.Config.Volumes // {}),
          healthcheck: (.Config.Healthcheck // null),
          stopSignal: (.Config.StopSignal // ""),
          shell: (.Config.Shell // [])
        },
        rootfsLayers: (.RootFS.Layers // [])
      }
    | . as $canonical
    | if
        ($canonical.architecture | type == "string" and length > 0)
        and ($canonical.os | type == "string" and length > 0)
        and ($canonical.config.user | type == "string")
        and ($canonical.config.env | type == "array"
          and all(.[]; type == "string"))
        and ($canonical.config.entrypoint | type == "array"
          and all(.[]; type == "string"))
        and ($canonical.config.cmd | type == "array"
          and all(.[]; type == "string"))
        and ($canonical.config.workingDir | type == "string")
        and ($canonical.config.labels | type == "object")
        and ($canonical.config.exposedPorts | type == "object")
        and ($canonical.config.volumes | type == "object")
        and (($canonical.config.healthcheck == null)
          or ($canonical.config.healthcheck | type == "object"))
        and ($canonical.config.stopSignal | type == "string")
        and ($canonical.config.shell | type == "array"
          and all(.[]; type == "string"))
        and ($canonical.rootfsLayers | type == "array"
          and all(.[];
            type == "string"
            and test("^sha256:[0-9a-f]{64}$")))
      then $canonical
      else error("invalid Docker image content metadata")
      end
  '
}

canonicalize_image_config() {
  jq -ceS '
    if type == "object" then . else error("expected an image config object") end
    | {
        schemaVersion: 1,
        architecture: (.architecture // ""),
        os: (.os // ""),
        config: {
          user: (.config.User // ""),
          env: (.config.Env // []),
          entrypoint: (.config.Entrypoint // []),
          cmd: (.config.Cmd // []),
          workingDir: (.config.WorkingDir // ""),
          labels: (.config.Labels // {}),
          exposedPorts: (.config.ExposedPorts // {}),
          volumes: (.config.Volumes // {}),
          healthcheck: (.config.Healthcheck // null),
          stopSignal: (.config.StopSignal // ""),
          shell: (.config.Shell // [])
        },
        rootfsLayers: (.rootfs.diff_ids // [])
      }
    | . as $canonical
    | if
        ($canonical.architecture | type == "string" and length > 0)
        and ($canonical.os | type == "string" and length > 0)
        and ($canonical.config.user | type == "string")
        and ($canonical.config.env | type == "array"
          and all(.[]; type == "string"))
        and ($canonical.config.entrypoint | type == "array"
          and all(.[]; type == "string"))
        and ($canonical.config.cmd | type == "array"
          and all(.[]; type == "string"))
        and ($canonical.config.workingDir | type == "string")
        and ($canonical.config.labels | type == "object")
        and ($canonical.config.exposedPorts | type == "object")
        and ($canonical.config.volumes | type == "object")
        and (($canonical.config.healthcheck == null)
          or ($canonical.config.healthcheck | type == "object"))
        and ($canonical.config.stopSignal | type == "string")
        and ($canonical.config.shell | type == "array"
          and all(.[]; type == "string"))
        and ($canonical.rootfsLayers | type == "array"
          and all(.[];
            type == "string"
            and test("^sha256:[0-9a-f]{64}$")))
      then $canonical
      else error("invalid OCI image content metadata")
      end
  '
}

[[ "$#" -eq 2 ]] || usage
mode="$1"
source_value="$2"
canonical=""

case "${mode}" in
  docker)
    [[ -n "${source_value}" && "${source_value}" != *$'\n'* ]] || usage
    docker_bin="${DOCKER_BIN:-docker}"
    command -v "$docker_bin" >/dev/null 2>&1 || {
      echo "Docker image fingerprinting requires docker." >&2
      exit 2
    }
    canonical="$(
      "$docker_bin" image inspect -- "${source_value}" | canonicalize_docker_inspect
    )"
    ;;
  config)
    if [[ "${source_value}" == "-" ]]; then
      canonical="$(canonicalize_image_config)"
    else
      [[ -f "${source_value}" && ! -L "${source_value}" ]] || {
        echo "Image config must be a regular, non-symbolic-link file." >&2
        exit 2
      }
      canonical="$(canonicalize_image_config < "${source_value}")"
    fi
    ;;
  *)
    usage
    ;;
esac

digest="$(
  printf '%s\n' "${canonical}" | sha256sum | awk 'NR == 1 { print $1 }'
)"
[[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Could not calculate the image content fingerprint." >&2
  exit 1
}
printf 'sha256:%s\n' "${digest}"
