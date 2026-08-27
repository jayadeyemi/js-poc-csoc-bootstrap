#!/usr/bin/env bash
# Read-only comparison of one tracked CSOC profile with its owned Magnum record.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/credentials.bash"
source "${REPO_ROOT}/scripts/lib/openstack.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
csoc::load_profile "${REPO_ROOT}"

bash "${REPO_ROOT}/scripts/tools/validate-clusters.sh" >/dev/null

if [[ ! -f "${MAGNUM_STATE_FILE}" ]]; then
  log::warn "${CSOC_PROFILE} has no ownership state; the plan is CREATE, not an in-place change"
  printf 'profile=%s action=CREATE name=%s masters=%s workers=%s bounds=%s..%s\n' \
    "${CSOC_PROFILE}" "${MAGNUM_CLUSTER_NAME}" "${MAGNUM_MASTER_COUNT}" \
    "${MAGNUM_NODE_COUNT}" "${MAGNUM_MIN_NODE_COUNT}" "${MAGNUM_MAX_NODE_COUNT}"
  exit 0
fi

credentials::configure_magnum
cluster_id=$(os::owned_cluster_id "${MAGNUM_STATE_FILE}")
state_name=$(jq -r '.cluster_name' "${MAGNUM_STATE_FILE}")
state_template=$(jq -r '.template_id' "${MAGNUM_STATE_FILE}")
cluster_json=$(openstack coe cluster show "${cluster_id}" -f json) \
  || log::die "Owned Magnum cluster is unavailable: ${cluster_id}"
worker_json=$(openstack coe nodegroup show "${cluster_id}" default-worker -f json) \
  || log::die "Default worker node group is unavailable: ${cluster_id}"
master_json=$(openstack coe nodegroup show "${cluster_id}" default-master -f json) \
  || log::die "Default master node group is unavailable: ${cluster_id}"

actual_name=$(jq -r '.name // ""' <<<"${cluster_json}")
actual_status=$(jq -r '.status // "UNKNOWN"' <<<"${cluster_json}")
actual_health=$(jq -r '.health_status // "UNKNOWN"' <<<"${cluster_json}")
actual_template=$(jq -r '.cluster_template_id // ""' <<<"${cluster_json}")
actual_fixed_network=$(jq -r '.fixed_network // ""' <<<"${cluster_json}")
actual_fixed_subnet=$(jq -r '.fixed_subnet // ""' <<<"${cluster_json}")
actual_keypair=$(jq -r '.keypair // ""' <<<"${cluster_json}")
actual_master_count=$(jq -r '.node_count // ""' <<<"${master_json}")
actual_master_flavor=$(jq -r '.flavor_id // ""' <<<"${master_json}")
actual_worker_count=$(jq -r '.node_count // ""' <<<"${worker_json}")
actual_worker_flavor=$(jq -r '.flavor_id // ""' <<<"${worker_json}")
actual_worker_image=$(jq -r '.image_id // ""' <<<"${worker_json}")
actual_image_id=$(openstack image show "${actual_worker_image}" -f json | jq -r '.id // ""')
actual_min=$(jq -r '.min_node_count // ""' <<<"${worker_json}")
actual_max=$(jq -r '.max_node_count // ""' <<<"${worker_json}")
actual_boot_volume=$(jq -r '.labels.boot_volume_size // ""' <<<"${cluster_json}")

replacement=0
mutable=0
printf 'CSOC IaC plan: profile=%s uuid=%s status=%s health=%s\n' \
  "${CSOC_PROFILE}" "${cluster_id}" "${actual_status}" "${actual_health}"
printf '%-22s %-22s %-22s %s\n' FIELD CURRENT DESIRED ACTION

plan_field() {
  local field=$1 current=$2 desired=$3 policy=$4 action=no-op
  if [[ "${current}" != "${desired}" ]]; then
    action=${policy}
    case "${policy}" in
      replace-cluster) ((replacement += 1)) ;;
      in-place) ((mutable += 1)) ;;
    esac
  fi
  printf '%-22s %-22s %-22s %s\n' "${field}" "${current}" "${desired}" "${action}"
}

plan_field name "${actual_name}" "${MAGNUM_CLUSTER_NAME}" replace-cluster
plan_field ownership-name "${state_name}" "${MAGNUM_CLUSTER_NAME}" replace-cluster
plan_field template "${state_template}" "${MAGNUM_TEMPLATE_ID}" replace-cluster
plan_field live-template "${actual_template}" "${MAGNUM_TEMPLATE_ID}" replace-cluster
plan_field master-count "${actual_master_count}" "${MAGNUM_MASTER_COUNT}" replace-cluster
plan_field master-flavor "${actual_master_flavor}" "${MAGNUM_MASTER_FLAVOR}" replace-cluster
plan_field worker-flavor "${actual_worker_flavor}" "${MAGNUM_WORKER_FLAVOR}" replace-cluster
plan_field worker-image "${actual_worker_image}" "${MAGNUM_IMAGE_NAME}" replace-cluster
plan_field glance-image "${actual_image_id}" "${MAGNUM_IMAGE_ID}" replace-cluster
plan_field boot-volume-gib "${actual_boot_volume}" "${MAGNUM_BOOT_VOLUME_SIZE}" replace-cluster
plan_field fixed-network "${actual_fixed_network}" "${MAGNUM_FIXED_NETWORK}" replace-cluster
plan_field fixed-subnet "${actual_fixed_subnet}" "${MAGNUM_FIXED_SUBNET}" replace-cluster
plan_field keypair "${actual_keypair}" "${MAGNUM_KEYPAIR}" replace-cluster
plan_field worker-min "${actual_min}" "${MAGNUM_MIN_NODE_COUNT}" in-place
plan_field worker-max "${actual_max}" "${MAGNUM_MAX_NODE_COUNT}" in-place
printf '%-22s %-22s %-22s %s\n' worker-count "${actual_worker_count}" autoscaler-managed observe-only

if (( replacement > 0 )); then
  log::warn "Plan requires cluster replacement; rename and immutable spec changes are never applied in place"
  [[ "${CSOC_PLAN_FAIL_ON_REPLACEMENT:-false}" != true ]] \
    || log::die "Refusing mutable reconciliation while replacement changes are declared"
elif (( mutable > 0 )); then
  log::warn "Plan contains ${mutable} in-place worker-bound change(s)"
  log::info "Review, then run: make csoc-resize PROFILE=${CSOC_PROFILE} CONFIRM=${MAGNUM_CLUSTER_NAME}"
else
  log::success "Owned cluster matches its declarative CSOC profile"
fi
