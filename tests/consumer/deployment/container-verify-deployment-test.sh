#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

node --test "${REPO_ROOT}/@@VERIFIER_SOURCE@@/test/verifier.test.mjs"

echo "registry manual deployment verifier tests passed"
