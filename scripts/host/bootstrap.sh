#!/usr/bin/env bash
# Host wrapper: build the pinned image, then run the inner pipeline in it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"

log::step 1 "Build the pinned management image"
bash "${REPO_ROOT}/scripts/host/container/build.sh"
log::step 2 "Run the non-interactive inner bootstrap pipeline"
bash "${REPO_ROOT}/scripts/host/container/run.sh" bash scripts/bootstrap/pipeline.sh
