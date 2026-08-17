#!/usr/bin/env bash
# Build the Jetstream2 management container image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"

IMAGE_NAME="${JETSTREAM_IMAGE_NAME:-jetstream2-mgmt}"
IMAGE_TAG="${JETSTREAM_IMAGE_TAG:-latest}"
FULL_TAG="${IMAGE_NAME}:${IMAGE_TAG}"

log::step 1 "Building management container image: ${FULL_TAG}"

docker build \
  --tag "${FULL_TAG}" \
  --file "${REPO_ROOT}/container/Dockerfile" \
  "${REPO_ROOT}/container"

log::success "Image ready: ${FULL_TAG}"
