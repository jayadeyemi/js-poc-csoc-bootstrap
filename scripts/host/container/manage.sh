#!/usr/bin/env bash
# Manage one persistent, profile-specific operator container.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
csoc::load_profile "${REPO_ROOT}"

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
