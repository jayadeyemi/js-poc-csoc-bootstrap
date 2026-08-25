#!/usr/bin/env bash
# Run the Jetstream2 management container with credentials mounted read-only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"

IMAGE_NAME="${JETSTREAM_IMAGE_NAME:-jetstream2-mgmt}"
IMAGE_TAG="${JETSTREAM_IMAGE_TAG:-latest}"

HOST_MAGNUM_CLOUDS_YAML="${MAGNUM_CLOUDS_YAML:-${REPO_ROOT}/scripts/host/credentials/magnum-clouds.yaml}"
HOST_RUNTIME_CREDENTIALS_DIR="${RUNTIME_CREDENTIALS_DIR:-${REPO_ROOT}/scripts/host/credentials/accounts}"
CONTAINER_MAGNUM_CLOUDS_YAML=/run/csoc-credentials/magnum-clouds.yaml
CONTAINER_RUNTIME_CREDENTIALS_DIR=/run/csoc-credentials/accounts

# Kubeconfig directory on the host — persists kubeconfigs across container runs
KUBECONFIG_DIR="${KUBECONFIG_DIR:-${HOME}/.kube}"

[[ -f "${HOST_MAGNUM_CLOUDS_YAML}" ]] \
  || log::die "Magnum credential file not found: ${HOST_MAGNUM_CLOUDS_YAML}"
[[ -d "${HOST_RUNTIME_CREDENTIALS_DIR}" ]] \
  || log::die "Runtime credential directory not found: ${HOST_RUNTIME_CREDENTIALS_DIR}"

mkdir -p "${KUBECONFIG_DIR}" "${REPO_ROOT}/.state"
chmod 700 "${KUBECONFIG_DIR}" "${REPO_ROOT}/.state"

log::info "Starting management container (${IMAGE_NAME}:${IMAGE_TAG})"
log::info "  credentials : separated Magnum/runtime files → /run/csoc-credentials (ro)"
log::info "  kubeconfig  : ${KUBECONFIG_DIR}  →  /home/jetstream/.kube"
log::info "  workspace   : ${WORKSPACE_ROOT}  →  /workspace"

docker_args=(--rm)
if [[ -t 0 && -t 1 ]]; then
  docker_args+=(--interactive --tty)
fi
command_args=("$@")
(( ${#command_args[@]} > 0 )) || command_args=(/bin/bash)

docker run "${docker_args[@]}" \
  --name "jetstream2-mgmt-$$" \
  --user "$(id -u):$(id -g)" \
  --env HOME=/home/jetstream \
  --env SHELL=/bin/bash \
  --tmpfs /run/csoc-credentials:rw,noexec,nosuid,nodev,size=1m \
  --volume "${HOST_MAGNUM_CLOUDS_YAML}:${CONTAINER_MAGNUM_CLOUDS_YAML}:ro" \
  --volume "${HOST_RUNTIME_CREDENTIALS_DIR}:${CONTAINER_RUNTIME_CREDENTIALS_DIR}:ro" \
  --volume "${KUBECONFIG_DIR}:/home/jetstream/.kube" \
  --volume "${WORKSPACE_ROOT}:/workspace" \
  --tmpfs /workspace/js-poc-csoc-bootstrap/scripts/host/credentials:rw,noexec,nosuid,nodev,size=1m \
  --workdir /workspace/js-poc-csoc-bootstrap \
  --env "MAGNUM_CLOUDS_YAML=${CONTAINER_MAGNUM_CLOUDS_YAML}" \
  --env "RUNTIME_CREDENTIALS_DIR=${CONTAINER_RUNTIME_CREDENTIALS_DIR}" \
  --env "OS_CLIENT_CONFIG_FILE=${CONTAINER_MAGNUM_CLOUDS_YAML}" \
  --env "OS_CLOUD=${OS_CLOUD:-openstack}" \
  "${IMAGE_NAME}:${IMAGE_TAG}" \
  "${command_args[@]}"
