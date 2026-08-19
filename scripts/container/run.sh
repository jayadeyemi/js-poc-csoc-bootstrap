#!/usr/bin/env bash
# Run the Jetstream2 management container with credentials mounted read-only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"

IMAGE_NAME="${JETSTREAM_IMAGE_NAME:-jetstream2-mgmt}"
IMAGE_TAG="${JETSTREAM_IMAGE_TAG:-latest}"

# Credential discovery: explicit override, repository runtime credentials,
# then the standard OpenStack user configuration directory.
if [[ -n "${CREDENTIALS_DIR:-}" ]]; then
  RESOLVED_CREDENTIALS_DIR="${CREDENTIALS_DIR}"
elif [[ -f "${REPO_ROOT}/credentials/clouds.yaml" ]]; then
  RESOLVED_CREDENTIALS_DIR="${REPO_ROOT}/credentials"
else
  RESOLVED_CREDENTIALS_DIR="${HOME}/.config/openstack"
fi

# Kubeconfig directory on the host — persists kubeconfigs across container runs
KUBECONFIG_DIR="${KUBECONFIG_DIR:-${HOME}/.kube}"

if [[ ! -d "${RESOLVED_CREDENTIALS_DIR}" ]]; then
  log::die "Credentials directory not found: ${RESOLVED_CREDENTIALS_DIR}\nSee credentials/README.md"
fi

[[ -f "${RESOLVED_CREDENTIALS_DIR}/clouds.yaml" ]] \
  || log::die "clouds.yaml not found in ${RESOLVED_CREDENTIALS_DIR}"

mkdir -p "${KUBECONFIG_DIR}"

log::info "Starting management container (${IMAGE_NAME}:${IMAGE_TAG})"
log::info "  credentials : ${RESOLVED_CREDENTIALS_DIR}  →  /home/jetstream/.config/openstack  (ro)"
log::info "  kubeconfig  : ${KUBECONFIG_DIR}  →  /home/jetstream/.kube"
log::info "  workspace   : ${REPO_ROOT}  →  /workspace"

docker run --rm -it \
  --name "jetstream2-mgmt-$$" \
  --volume "${RESOLVED_CREDENTIALS_DIR}:/home/jetstream/.config/openstack:ro" \
  --volume "${KUBECONFIG_DIR}:/home/jetstream/.kube" \
  --volume "${REPO_ROOT}:/workspace" \
  --env "OS_CLOUD=${OS_CLOUD:-openstack}" \
  "${IMAGE_NAME}:${IMAGE_TAG}" \
  "$@"
