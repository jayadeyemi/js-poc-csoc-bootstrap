#!/usr/bin/env bash
# Manage one persistent, profile-specific operator container.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
csoc::load_profile "${REPO_ROOT}"

WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
CONTEXT_NAME=$(basename "${WORKSPACE_ROOT}")
[[ "${CONTEXT_NAME}" == "${CSOC_PROFILE}" ]] \
  || log::die "Folder context ${CONTEXT_NAME} cannot run PROFILE=${CSOC_PROFILE}"
for repository in js-poc-csoc-bootstrap js-poc-csoc-app-catalog js-poc-csoc-fleet; do
  current_branch=$(git -C "${WORKSPACE_ROOT}/${repository}" branch --show-current)
  [[ "${current_branch}" == "environment/${CSOC_PROFILE}" ]] \
    || log::die "${repository} must be on environment/${CSOC_PROFILE}, not ${current_branch:-detached}"
done

ACTION=${1:-status}
CONTAINER_NAME="jetstream2-csoc-${CSOC_PROFILE}"

case "${ACTION}" in
  up)
    if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
      log::success "${CONTAINER_NAME} already exists"
      exit 0
    fi
    CSOC_CONTAINER_DETACH=true CSOC_CONTAINER_NAME="${CONTAINER_NAME}" \
      bash "${SCRIPT_DIR}/run.sh"
    ;;
  shell)
    docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1 \
      || log::die "${CONTAINER_NAME} is not running; use PROFILE=${CSOC_PROFILE} make container-up"
    tty_args=()
    [[ -t 0 && -t 1 ]] && tty_args=(--interactive --tty)
    docker exec "${tty_args[@]}" --workdir /workspace/js-poc-csoc-bootstrap \
      "${CONTAINER_NAME}" /bin/bash
    ;;
  status)
    if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
      docker ps --filter "name=^/${CONTAINER_NAME}$" \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
    else
      log::info "${CONTAINER_NAME} does not exist"
    fi
    ;;
  stop)
    docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1 \
      || { log::info "${CONTAINER_NAME} is already absent"; exit 0; }
    docker stop "${CONTAINER_NAME}" >/dev/null
    log::success "Stopped ${CONTAINER_NAME}; its --rm container was removed"
    ;;
  *) log::die "Usage: $0 {up|shell|status|stop}" ;;
esac
