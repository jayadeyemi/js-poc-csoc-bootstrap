#!/usr/bin/env bash
# Run the Jetstream2 management container with credentials mounted read-only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
REFERENCES_ROOT="$(cd "${WORKSPACE_ROOT}/../references" && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
csoc::load_profile "${REPO_ROOT}"

CONTEXT_NAME=$(basename "${WORKSPACE_ROOT}")
[[ "${CONTEXT_NAME}" == "${CSOC_PROFILE}" ]] \
  || log::die "Folder context ${CONTEXT_NAME} cannot run PROFILE=${CSOC_PROFILE}"

IMAGE_NAME="${JETSTREAM_IMAGE_NAME:-jetstream2-mgmt}"
IMAGE_TAG="${JETSTREAM_IMAGE_TAG:-latest}"

HOST_MAGNUM_CLOUDS_YAML="${MAGNUM_CLOUDS_YAML:-${REPO_ROOT}/scripts/host/credentials/magnum-clouds.yaml}"
HOST_RUNTIME_CREDENTIALS_DIR="${RUNTIME_CREDENTIALS_DIR:-${REPO_ROOT}/scripts/host/credentials/accounts}"
CONTAINER_MAGNUM_CLOUDS_YAML=/run/csoc-credentials/magnum-clouds.yaml
CONTAINER_RUNTIME_CREDENTIALS_DIR=/run/csoc-credentials/accounts

# Kubeconfig directory on the host — persists kubeconfigs across container runs
KUBECONFIG_DIR="${KUBECONFIG_DIR:-${MAGNUM_KUBECONFIG_DIR}}"
CSOC_CONTAINER_DETACH="${CSOC_CONTAINER_DETACH:-false}"
CSOC_CONTAINER_NAME="${CSOC_CONTAINER_NAME:-jetstream2-csoc-${CSOC_PROFILE}-$$}"

[[ -f "${HOST_MAGNUM_CLOUDS_YAML}" ]] \
  || log::die "Magnum credential file not found: ${HOST_MAGNUM_CLOUDS_YAML}"
[[ -d "${HOST_RUNTIME_CREDENTIALS_DIR}" ]] \
  || log::die "Runtime credential directory not found: ${HOST_RUNTIME_CREDENTIALS_DIR}"

mkdir -p "${KUBECONFIG_DIR}" "${REPO_ROOT}/.state"
chmod 700 "${KUBECONFIG_DIR}" "${REPO_ROOT}/.state"

log::info "Starting ${CSOC_PROFILE} management container (${IMAGE_NAME}:${IMAGE_TAG})"
log::info "  credentials : separated Magnum/runtime files → /run/csoc-credentials (ro)"
log::info "  kubeconfig  : ${KUBECONFIG_DIR}  →  /home/jetstream/.kube"
log::info "  workspace   : ${WORKSPACE_ROOT}  →  /workspace"
log::info "  references  : ${REFERENCES_ROOT}  →  /references (ro)"

docker_args=(--rm)
if [[ "${CSOC_CONTAINER_DETACH}" == true ]]; then
  docker_args+=(--detach)
elif [[ -t 0 && -t 1 ]]; then
  docker_args+=(--interactive --tty)
fi
command_args=("$@")
if (( ${#command_args[@]} == 0 )); then
  if [[ "${CSOC_CONTAINER_DETACH}" == true ]]; then
    command_args=(sleep infinity)
  else
    command_args=(/bin/bash)
  fi
fi

docker run "${docker_args[@]}" \
  --name "${CSOC_CONTAINER_NAME}" \
  --user "$(id -u):$(id -g)" \
  --env HOME=/home/jetstream \
  --env SHELL=/bin/bash \
  --tmpfs /run/csoc-credentials:rw,noexec,nosuid,nodev,size=1m \
  --volume "${HOST_MAGNUM_CLOUDS_YAML}:${CONTAINER_MAGNUM_CLOUDS_YAML}:ro" \
  --volume "${HOST_RUNTIME_CREDENTIALS_DIR}:${CONTAINER_RUNTIME_CREDENTIALS_DIR}:ro" \
  --volume "${KUBECONFIG_DIR}:/home/jetstream/.kube" \
  --volume "${WORKSPACE_ROOT}:/workspace" \
  --volume "${REFERENCES_ROOT}:/references:ro" \
  --tmpfs /workspace/js-poc-csoc-bootstrap/scripts/host/credentials:rw,noexec,nosuid,nodev,size=1m \
  --workdir /workspace/js-poc-csoc-bootstrap \
  --env "MAGNUM_CLOUDS_YAML=${CONTAINER_MAGNUM_CLOUDS_YAML}" \
  --env "RUNTIME_CREDENTIALS_DIR=${CONTAINER_RUNTIME_CREDENTIALS_DIR}" \
  --env "OS_CLIENT_CONFIG_FILE=${CONTAINER_MAGNUM_CLOUDS_YAML}" \
  --env "OS_CLOUD=${OS_CLOUD:-openstack}" \
  --env "CSOC_PROFILE=${CSOC_PROFILE}" \
  --env "CSOC_BOOTSTRAP_REVISION=${CSOC_BOOTSTRAP_REVISION}" \
  --env "CSOC_CATALOG_REVISION=${CSOC_CATALOG_REVISION}" \
  --env "CSOC_FLEET_REVISION=${CSOC_FLEET_REVISION}" \
  "${IMAGE_NAME}:${IMAGE_TAG}" \
  "${command_args[@]}"
