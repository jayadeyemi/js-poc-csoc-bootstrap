#!/usr/bin/env bash
# Reconcile the default Magnum worker node group's explicit autoscaling bounds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/openstack.bash"
source "${REPO_ROOT}/scripts/lib/credentials.bash"
source "${REPO_ROOT}/iac/magnum/cluster.env"

STATE_FILE="${MAGNUM_STATE_FILE:-${REPO_ROOT}/.state/magnum-cluster.json}"
credentials::configure_magnum
CLUSTER_ID=$(os::verify_owned_cluster "${STATE_FILE}" "${MAGNUM_CLUSTER_NAME}")
CLUSTER_JSON=$(openstack coe cluster show "${CLUSTER_ID}" -f json)
status=$(jq -r '.status // "UNKNOWN"' <<<"${CLUSTER_JSON}")
health=$(jq -r '.health_status // "UNKNOWN"' <<<"${CLUSTER_JSON}")
[[ ( "${status}" == CREATE_COMPLETE || "${status}" == UPDATE_COMPLETE ) \
   && "${health}" == HEALTHY ]] \
  || log::die "Cluster must be complete and HEALTHY before reconciling node-group bounds"

NODEGROUP_JSON=$(openstack coe nodegroup show "${CLUSTER_ID}" default-worker -f json)
node_count=$(jq -r '.node_count' <<<"${NODEGROUP_JSON}")
min_count=$(jq -r '.min_node_count' <<<"${NODEGROUP_JSON}")
max_count=$(jq -r '.max_node_count // ""' <<<"${NODEGROUP_JSON}")
(( node_count >= MAGNUM_MIN_NODE_COUNT && node_count <= MAGNUM_MAX_NODE_COUNT )) \
  || log::die "Default worker count ${node_count} is outside declared bounds"

patches=()
[[ "${min_count}" == "${MAGNUM_MIN_NODE_COUNT}" ]] \
  || patches+=("/min_node_count=${MAGNUM_MIN_NODE_COUNT}")
[[ "${max_count}" == "${MAGNUM_MAX_NODE_COUNT}" ]] \
  || patches+=("/max_node_count=${MAGNUM_MAX_NODE_COUNT}")
if (( ${#patches[@]} == 0 )); then
  log::success "Default worker bounds already match ${MAGNUM_MIN_NODE_COUNT}..${MAGNUM_MAX_NODE_COUNT}"
  exit 0
fi

log::warn "Reconciling default worker bounds to ${MAGNUM_MIN_NODE_COUNT}..${MAGNUM_MAX_NODE_COUNT}"
openstack coe nodegroup update "${CLUSTER_ID}" default-worker replace "${patches[@]}"

deadline=$((SECONDS + MAGNUM_NODEGROUP_UPDATE_TIMEOUT))
while (( SECONDS < deadline )); do
  NODEGROUP_JSON=$(openstack coe nodegroup show "${CLUSTER_ID}" default-worker -f json)
  status=$(jq -r '.status // "UNKNOWN"' <<<"${NODEGROUP_JSON}")
  min_count=$(jq -r '.min_node_count' <<<"${NODEGROUP_JSON}")
  max_count=$(jq -r '.max_node_count // ""' <<<"${NODEGROUP_JSON}")
  log::info "nodegroup status=${status} bounds=${min_count}..${max_count:-unset}"
  [[ "${status}" != *FAILED* ]] || log::die "Default worker node-group update failed"
  if [[ "${status}" == UPDATE_COMPLETE \
     && "${min_count}" == "${MAGNUM_MIN_NODE_COUNT}" \
     && "${max_count}" == "${MAGNUM_MAX_NODE_COUNT}" ]]; then
    log::success "Default worker bounds are ${min_count}..${max_count}"
    exit 0
  fi
  sleep "${MAGNUM_WAIT_INTERVAL}"
done
log::die "Timed out reconciling default worker node-group bounds"
