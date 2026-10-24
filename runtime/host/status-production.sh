#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

MYSCOUTEE_SERVER_DIR="${REPO_ROOT}/server" "${SCRIPT_DIR}/myscoutee-compose.sh" ps
