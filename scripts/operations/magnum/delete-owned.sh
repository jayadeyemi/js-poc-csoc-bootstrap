#!/usr/bin/env bash
# Delete exactly one reviewed, bootstrap-owned Magnum cluster UUID.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/openstack.bash"
source "${REPO_ROOT}/scripts/lib/credentials.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
csoc::load_profile "${REPO_ROOT}"

(( $# == 1 )) || log::die "Usage: $0 <reviewed-cluster-uuid>"
REQUESTED_ID=$1
STATE_FILE="${MAGNUM_STATE_FILE:-${REPO_ROOT}/.state/magnum-cluster.json}"
credentials::configure_magnum
OWNED_ID=$(os::owned_cluster_id "${STATE_FILE}")
[[ "${REQUESTED_ID}" == "${OWNED_ID}" ]] \
  || log::die "Requested UUID does not match owned UUID ${OWNED_ID}"
if ! CLUSTER_JSON=$(openstack coe cluster show "${OWNED_ID}" -f json 2>/dev/null); then
  unlink -- "${STATE_FILE}"
  log::success "Owned cluster ${OWNED_ID} is absent and ownership state is removed"
  exit 0
fi
[[ $(jq -r '.name' <<<"${CLUSTER_JSON}") == "${MAGNUM_CLUSTER_NAME}" ]] \
  || log::die "Owned UUID name changed; refusing deletion"
INITIAL_STATUS=$(jq -r '.status // "UNKNOWN"' <<<"${CLUSTER_JSON}")
[[ "${INITIAL_STATUS}" != DELETE_FAILED ]] \
  || log::die "Owned cluster is already DELETE_FAILED; do not resend or remove finalizers"

bash "${REPO_ROOT}/scripts/operations/magnum/diagnose.sh" "${OWNED_ID}" >/dev/null
if [[ "${INITIAL_STATUS}" == DELETE_IN_PROGRESS || "${INITIAL_STATUS}" == DELETE_COMPLETE ]]; then
  log::warn "Owned UUID ${OWNED_ID} is already ${INITIAL_STATUS}; monitoring without resubmitting"
else
  log::warn "Sending one delete request for reviewed owned UUID ${OWNED_ID}"
  set +e
  openstack coe cluster delete "${OWNED_ID}"
  delete_rc=$?
  set -e
  (( delete_rc == 0 )) || log::warn "Delete client returned ${delete_rc}; polling the accepted UUID without resubmitting"
fi

deadline=$((SECONDS + MAGNUM_DELETE_TIMEOUT))
while (( SECONDS < deadline )); do
  if ! CURRENT_JSON=$(openstack coe cluster show "${OWNED_ID}" -f json 2>/dev/null); then
    unlink -- "${STATE_FILE}"
    log::success "Owned cluster ${OWNED_ID} is deleted and ownership state is removed"
    exit 0
  fi
  status=$(jq -r '.status // "UNKNOWN"' <<<"${CURRENT_JSON}")
  reason=$(jq -r '.status_reason // ""' <<<"${CURRENT_JSON}")
  log::info "delete status=${status} reason=${reason:-none}"
  [[ "${status}" != DELETE_FAILED ]] \
    || log::die "Owned cluster deletion failed: ${reason}"
  sleep "${MAGNUM_WAIT_INTERVAL}"
done
log::die "Deletion did not complete in ${MAGNUM_DELETE_TIMEOUT}s. Do not resend or remove finalizers."
