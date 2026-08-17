#!/usr/bin/env bash
# Run the Jetstream2 management container with credentials mounted read-only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"

IMAGE_NAME="${JETSTREAM_IMAGE_NAME:-jetstream2-mgmt}"
IMAGE_TAG="${JETSTREAM_IMAGE_TAG:-latest}"

# Credentials directory on the host — defaults to ~/.config/openstack
CREDENTIALS_DIR="${CREDENTIALS_DIR:-${HOME}/.config/openstack}"

# Kubeconfig directory on the host — persists kubeconfigs across container runs
KUBECONFIG_DIR="${KUBECONFIG_DIR:-${HOME}/.kube}"

if [[ ! -d "${CREDENTIALS_DIR}" ]]; then
  log::die "Credentials directory not found: ${CREDENTIALS_DIR}\nSee credentials/README.md"
fi

if [[ ! -f "${CREDENTIALS_DIR}/clouds.yaml" ]]; then
  log::warn "clouds.yaml not found in ${CREDENTIALS_DIR}. Container may lack OpenStack access."
fi

mkdir -p "${KUBECONFIG_DIR}"

log::info "Starting management container (${IMAGE_NAME}:${IMAGE_TAG})"
log::info "  credentials : ${CREDENTIALS_DIR}  →  /home/jetstream/.config/openstack  (ro)"
log::info "  kubeconfig  : ${KUBECONFIG_DIR}  →  /home/jetstream/.kube"
log::info "  workspace   : ${REPO_ROOT}  →  /workspace"

docker run --rm -it \
  --name "jetstream2-mgmt-$$" \
  --volume "${CREDENTIALS_DIR}:/home/jetstream/.config/openstack:ro" \
  --volume "${KUBECONFIG_DIR}:/home/jetstream/.kube" \
  --volume "${REPO_ROOT}:/workspace" \
  --env "OS_CLOUD=${OS_CLOUD:-jetstream2}" \
  "${IMAGE_NAME}:${IMAGE_TAG}" \
  "$@"
