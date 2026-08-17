#!/usr/bin/env bash
# Poll until the Magnum cluster reaches a target status (default: CREATE_COMPLETE).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"
source "${REPO_ROOT}/scripts/lib/openstack.sh"

source "${REPO_ROOT}/iac/magnum/cluster.env"

TARGET_STATUS="${1:-CREATE_COMPLETE}"
TIMEOUT="${MAGNUM_WAIT_TIMEOUT:-1800}"   # seconds
INTERVAL=30

log::info "Waiting for cluster '${MAGNUM_CLUSTER_NAME}' → ${TARGET_STATUS} (timeout ${TIMEOUT}s)"

elapsed=0
while (( elapsed < TIMEOUT )); do
  status=$(os::cluster_status "${MAGNUM_CLUSTER_NAME}")

  case "${status}" in
    "${TARGET_STATUS}")
      log::success "Cluster reached status: ${status}"
      exit 0
      ;;
    *FAILED*)
      log::die "Cluster entered failed state: ${status}"
      ;;
    NOT_FOUND)
      log::die "Cluster '${MAGNUM_CLUSTER_NAME}' not found. Run 'make magnum-provision' first."
      ;;
    *)
      log::info "Current status: ${status} — waiting ${INTERVAL}s ..."
      sleep "${INTERVAL}"
      (( elapsed += INTERVAL ))
      ;;
  esac
done

log::die "Timed out after ${TIMEOUT}s waiting for status '${TARGET_STATUS}'."
