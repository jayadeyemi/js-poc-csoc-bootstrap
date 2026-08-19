#!/usr/bin/env bash
# Build the Jetstream2 management container image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"
source "${REPO_ROOT}/versions.env"

IMAGE_NAME="${JETSTREAM_IMAGE_NAME:-jetstream2-mgmt}"
IMAGE_TAG="${JETSTREAM_IMAGE_TAG:-latest}"
FULL_TAG="${IMAGE_NAME}:${IMAGE_TAG}"

log::step 1 "Building management container image: ${FULL_TAG}"

docker build \
  --tag "${FULL_TAG}" \
  --file "${REPO_ROOT}/container/Dockerfile" \
  --build-arg "KUBECTL_VERSION=${KUBECTL_VERSION}" \
  --build-arg "HELM_VERSION=${HELM_VERSION}" \
  --build-arg "YQ_VERSION=${YQ_VERSION}" \
  --build-arg "ARGOCD_CLI_VERSION=${ARGOCD_CLI_VERSION}" \
  --build-arg "OPENSTACK_CLIENT_VERSION=${OPENSTACK_CLIENT_VERSION}" \
  --build-arg "MAGNUM_CLIENT_VERSION=${MAGNUM_CLIENT_VERSION}" \
  --build-arg "OCTAVIA_CLIENT_VERSION=${OCTAVIA_CLIENT_VERSION}" \
  --build-arg "DESIGNATE_CLIENT_VERSION=${DESIGNATE_CLIENT_VERSION}" \
  --build-arg "HEAT_CLIENT_VERSION=${HEAT_CLIENT_VERSION}" \
  "${REPO_ROOT}/container"

log::success "Image ready: ${FULL_TAG}"
