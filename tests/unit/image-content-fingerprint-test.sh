#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGING_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
FINGERPRINT_SCRIPT="${PACKAGING_DIR}/release/lib/image-content-fingerprint.sh"

fail() {
  echo "image-content-fingerprint-test: $*" >&2
  exit 1
}

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    fail "command unexpectedly succeeded: $*"
  fi
}

[[ -x "${FINGERPRINT_SCRIPT}" ]] \
  || fail "fingerprint helper is missing or not executable"
bash -n "${FINGERPRINT_SCRIPT}"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

DOCKER_INSPECT_A="${TEST_ROOT}/docker-inspect-a.json"
DOCKER_INSPECT_B="${TEST_ROOT}/docker-inspect-b.json"
OCI_CONFIG="${TEST_ROOT}/oci-config.json"
OCI_CONFIG_CMD_CHANGED="${TEST_ROOT}/oci-config-cmd-changed.json"
OCI_CONFIG_LAYER_CHANGED="${TEST_ROOT}/oci-config-layer-changed.json"
INVALID_CONFIG="${TEST_ROOT}/invalid-config.json"
FAKE_BIN="${TEST_ROOT}/bin"
DOCKER_ARGS="${TEST_ROOT}/docker-args"
mkdir -p "${FAKE_BIN}"

cat > "${DOCKER_INSPECT_A}" <<'JSON'
[
  {
    "Id": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "Created": "2026-07-30T06:00:00Z",
    "Architecture": "amd64",
    "Os": "linux",
    "GraphDriver": {
      "Name": "overlay2",
      "Data": {
        "UpperDir": "/var/lib/docker/overlay2/daemon-a/diff"
      }
    },
    "Config": {
      "User": "10001:10001",
      "Env": [
        "LANG=C.UTF-8",
        "APP_MODE=production"
      ],
      "Entrypoint": [
        "/usr/local/bin/entrypoint"
      ],
      "Cmd": [
        "serve",
        "--port=8080"
      ],
      "WorkingDir": "/srv/app",
      "Labels": {
        "com.example.component": "api",
        "com.example.version": "1.0.0"
      },
      "ExposedPorts": {
        "8080/tcp": {}
      },
      "Volumes": {
        "/srv/app/data": {}
      },
      "Healthcheck": {
        "Test": [
          "CMD",
          "/usr/local/bin/healthcheck"
        ],
        "Interval": 30000000000,
        "Timeout": 5000000000,
        "Retries": 3
      },
      "StopSignal": "SIGTERM",
      "Shell": [
        "/bin/sh",
        "-c"
      ]
    },
    "RootFS": {
      "Type": "layers",
      "Layers": [
        "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        "sha256:2222222222222222222222222222222222222222222222222222222222222222"
      ]
    }
  }
]
JSON

cat > "${DOCKER_INSPECT_B}" <<'JSON'
[
  {
    "Id": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "Created": "2030-01-01T00:00:00Z",
    "Architecture": "amd64",
    "Os": "linux",
    "GraphDriver": {
      "Name": "overlayfs",
      "Data": {
        "UpperDir": "/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/daemon-b/fs"
      }
    },
    "Config": {
      "User": "10001:10001",
      "Env": [
        "LANG=C.UTF-8",
        "APP_MODE=production"
      ],
      "Entrypoint": [
        "/usr/local/bin/entrypoint"
      ],
      "Cmd": [
        "serve",
        "--port=8080"
      ],
      "WorkingDir": "/srv/app",
      "Labels": {
        "com.example.version": "1.0.0",
        "com.example.component": "api"
      },
      "ExposedPorts": {
        "8080/tcp": {}
      },
      "Volumes": {
        "/srv/app/data": {}
      },
      "Healthcheck": {
        "Test": [
          "CMD",
          "/usr/local/bin/healthcheck"
        ],
        "Interval": 30000000000,
        "Timeout": 5000000000,
        "Retries": 3
      },
      "StopSignal": "SIGTERM",
      "Shell": [
        "/bin/sh",
        "-c"
      ]
    },
    "RootFS": {
      "Type": "layers",
      "Layers": [
        "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        "sha256:2222222222222222222222222222222222222222222222222222222222222222"
      ]
    }
  }
]
JSON

cat > "${OCI_CONFIG}" <<'JSON'
{
  "architecture": "amd64",
  "os": "linux",
  "created": "2025-12-24T12:00:00Z",
  "config": {
    "User": "10001:10001",
    "Env": [
      "LANG=C.UTF-8",
      "APP_MODE=production"
    ],
    "Entrypoint": [
      "/usr/local/bin/entrypoint"
    ],
    "Cmd": [
      "serve",
      "--port=8080"
    ],
    "WorkingDir": "/srv/app",
    "Labels": {
      "com.example.component": "api",
      "com.example.version": "1.0.0"
    },
    "ExposedPorts": {
      "8080/tcp": {}
    },
    "Volumes": {
      "/srv/app/data": {}
    },
    "Healthcheck": {
      "Test": [
        "CMD",
        "/usr/local/bin/healthcheck"
      ],
      "Interval": 30000000000,
      "Timeout": 5000000000,
      "Retries": 3
    },
    "StopSignal": "SIGTERM",
    "Shell": [
      "/bin/sh",
      "-c"
    ]
  },
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:1111111111111111111111111111111111111111111111111111111111111111",
      "sha256:2222222222222222222222222222222222222222222222222222222222222222"
    ]
  },
  "history": [
    {
      "created": "2025-12-24T12:00:00Z",
      "created_by": "build daemon specific metadata"
    }
  ]
}
JSON

cat > "${OCI_CONFIG_CMD_CHANGED}" <<'JSON'
{
  "architecture": "amd64",
  "os": "linux",
  "config": {
    "User": "10001:10001",
    "Env": ["LANG=C.UTF-8", "APP_MODE=production"],
    "Entrypoint": ["/usr/local/bin/entrypoint"],
    "Cmd": ["serve", "--port=9090"],
    "WorkingDir": "/srv/app",
    "Labels": {
      "com.example.component": "api",
      "com.example.version": "1.0.0"
    },
    "ExposedPorts": {"8080/tcp": {}},
    "Volumes": {"/srv/app/data": {}},
    "Healthcheck": {
      "Test": ["CMD", "/usr/local/bin/healthcheck"],
      "Interval": 30000000000,
      "Timeout": 5000000000,
      "Retries": 3
    },
    "StopSignal": "SIGTERM",
    "Shell": ["/bin/sh", "-c"]
  },
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:1111111111111111111111111111111111111111111111111111111111111111",
      "sha256:2222222222222222222222222222222222222222222222222222222222222222"
    ]
  }
}
JSON

cat > "${OCI_CONFIG_LAYER_CHANGED}" <<'JSON'
{
  "architecture": "amd64",
  "os": "linux",
  "config": {
    "User": "10001:10001",
    "Env": ["LANG=C.UTF-8", "APP_MODE=production"],
    "Entrypoint": ["/usr/local/bin/entrypoint"],
    "Cmd": ["serve", "--port=8080"],
    "WorkingDir": "/srv/app",
    "Labels": {
      "com.example.component": "api",
      "com.example.version": "1.0.0"
    },
    "ExposedPorts": {"8080/tcp": {}},
    "Volumes": {"/srv/app/data": {}},
    "Healthcheck": {
      "Test": ["CMD", "/usr/local/bin/healthcheck"],
      "Interval": 30000000000,
      "Timeout": 5000000000,
      "Retries": 3
    },
    "StopSignal": "SIGTERM",
    "Shell": ["/bin/sh", "-c"]
  },
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:1111111111111111111111111111111111111111111111111111111111111111",
      "sha256:3333333333333333333333333333333333333333333333333333333333333333"
    ]
  }
}
JSON

cat > "${INVALID_CONFIG}" <<'JSON'
{
  "architecture": "amd64",
  "os": "linux",
  "config": {
    "Cmd": "serve"
  },
  "rootfs": {
    "diff_ids": [
      "not-a-sha256-digest"
    ]
  }
}
JSON

cat > "${FAKE_BIN}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 4
  || "$1" != "image"
  || "$2" != "inspect"
  || "$3" != "--"
  || "$4" != "fixture-image" ]]; then
  echo "unexpected docker invocation: $*" >&2
  exit 97
fi
printf '%s\n' "$@" > "${FAKE_DOCKER_ARGS_FILE:?}"
cat -- "${FAKE_DOCKER_INSPECT_JSON:?}"
SH
chmod 0755 "${FAKE_BIN}/docker"

OCI_FINGERPRINT="$("${FINGERPRINT_SCRIPT}" config "${OCI_CONFIG}")"
[[ "${OCI_FINGERPRINT}" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || fail "config mode returned a malformed fingerprint"

STDIN_FINGERPRINT="$("${FINGERPRINT_SCRIPT}" config - < "${OCI_CONFIG}")"
diff -u \
  <(printf '%s\n' "${OCI_FINGERPRINT}") \
  <(printf '%s\n' "${STDIN_FINGERPRINT}") \
  || fail "config file and stdin modes produced different fingerprints"

export FAKE_DOCKER_ARGS_FILE="${DOCKER_ARGS}"
export FAKE_DOCKER_INSPECT_JSON="${DOCKER_INSPECT_A}"
DOCKER_FINGERPRINT_A="$(
  PATH="${FAKE_BIN}:${PATH}" "${FINGERPRINT_SCRIPT}" docker fixture-image
)"
diff -u \
  <(printf '%s\n' "${OCI_FINGERPRINT}") \
  <(printf '%s\n' "${DOCKER_FINGERPRINT_A}") \
  || fail "Docker inspect and raw OCI config fingerprints differ"
diff -u \
  <(printf '%s\n' image inspect -- fixture-image) \
  "${DOCKER_ARGS}" \
  || fail "helper did not call 'docker image inspect -- IMAGE'"

export FAKE_DOCKER_INSPECT_JSON="${DOCKER_INSPECT_B}"
DOCKER_FINGERPRINT_B="$(
  PATH="${FAKE_BIN}:${PATH}" "${FINGERPRINT_SCRIPT}" docker fixture-image
)"
diff -u \
  <(printf '%s\n' "${DOCKER_FINGERPRINT_A}") \
  <(printf '%s\n' "${DOCKER_FINGERPRINT_B}") \
  || fail "daemon ID, Created, or GraphDriver changed the content fingerprint"

CMD_CHANGED_FINGERPRINT="$(
  "${FINGERPRINT_SCRIPT}" config "${OCI_CONFIG_CMD_CHANGED}"
)"
[[ "${CMD_CHANGED_FINGERPRINT}" != "${OCI_FINGERPRINT}" ]] \
  || fail "changing Cmd did not change the fingerprint"

LAYER_CHANGED_FINGERPRINT="$(
  "${FINGERPRINT_SCRIPT}" config "${OCI_CONFIG_LAYER_CHANGED}"
)"
[[ "${LAYER_CHANGED_FINGERPRINT}" != "${OCI_FINGERPRINT}" ]] \
  || fail "changing a rootfs layer did not change the fingerprint"

assert_fails "${FINGERPRINT_SCRIPT}" config "${INVALID_CONFIG}"
assert_fails "${FINGERPRINT_SCRIPT}" config "${TEST_ROOT}/missing.json"
assert_fails "${FINGERPRINT_SCRIPT}" unknown "${OCI_CONFIG}"
assert_fails "${FINGERPRINT_SCRIPT}" docker

echo "image-content-fingerprint-test: PASS"
