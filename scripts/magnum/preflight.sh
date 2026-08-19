#!/usr/bin/env bash
# Read-only validation for Magnum management-cluster prerequisites.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"
source "${REPO_ROOT}/scripts/lib/openstack.sh"
source "${REPO_ROOT}/iac/magnum/cluster.env"

STATE_FILE="${MAGNUM_STATE_FILE:-${REPO_ROOT}/.state/magnum-cluster.json}"

for required_command in openstack jq; do
  command -v "${required_command}" >/dev/null 2>&1 \
    || log::die "Required command not found: ${required_command}"
done

log::step 1 "Checking OpenStack authentication"
os::auth_check
PROJECT_ID=$(openstack token issue -f value -c project_id)
[[ -n "${PROJECT_ID}" ]] || log::die "Authenticated token has no project ID"

log::step 2 "Validating provider-owned Magnum template"
TEMPLATE_JSON=$(openstack coe cluster template show "${MAGNUM_TEMPLATE_ID}" -f json) \
  || log::die "Magnum template is unavailable: ${MAGNUM_TEMPLATE_ID}"
[[ $(jq -r '.uuid' <<<"${TEMPLATE_JSON}") == "${MAGNUM_TEMPLATE_ID}" ]] \
  || log::die "Magnum returned an unexpected template UUID"
[[ $(jq -r '.name' <<<"${TEMPLATE_JSON}") == "${MAGNUM_TEMPLATE_NAME}" ]] \
  || log::die "Template UUID no longer maps to ${MAGNUM_TEMPLATE_NAME}"
[[ $(jq -r '.public' <<<"${TEMPLATE_JSON}") == "true" ]] \
  || log::die "Selected Magnum template is not public"
[[ $(jq -r '.hidden' <<<"${TEMPLATE_JSON}") == "false" ]] \
  || log::die "Selected Magnum template is hidden"
[[ $(jq -r '.coe' <<<"${TEMPLATE_JSON}") == "kubernetes" ]] \
  || log::die "Selected template is not a Kubernetes template"

IMAGE_NAME=$(jq -r '.image_id' <<<"${TEMPLATE_JSON}")
IMAGE_JSON=$(openstack image show "${IMAGE_NAME}" -f json) \
  || log::die "Template image is unavailable: ${IMAGE_NAME}"
[[ $(jq -r '.status' <<<"${IMAGE_JSON}") == "active" ]] \
  || log::die "Template image is not active: ${IMAGE_NAME}"

log::step 3 "Validating network, flavors, keypair, and load balancer service"
NETWORK_JSON=$(openstack network show "${MAGNUM_EXTERNAL_NETWORK}" -f json) \
  || log::die "External network is unavailable: ${MAGNUM_EXTERNAL_NETWORK}"
[[ $(jq -r '."router:external"' <<<"${NETWORK_JSON}") == "true" ]] \
  || log::die "Network is not external: ${MAGNUM_EXTERNAL_NETWORK}"
MASTER_FLAVOR_JSON=$(openstack flavor show "${MAGNUM_MASTER_FLAVOR}" -f json 2>/dev/null) \
  || log::die "Master flavor is unavailable: ${MAGNUM_MASTER_FLAVOR}"
WORKER_FLAVOR_JSON=$(openstack flavor show "${MAGNUM_WORKER_FLAVOR}" -f json 2>/dev/null) \
  || log::die "Worker flavor is unavailable: ${MAGNUM_WORKER_FLAVOR}"
openstack keypair show "${MAGNUM_KEYPAIR}" -f json >/dev/null \
  || log::die "SSH keypair is unavailable: ${MAGNUM_KEYPAIR}"
openstack catalog show load-balancer -f json >/dev/null \
  || log::die "OpenStack load-balancer service is unavailable"

log::step 4 "Checking compute, network, and load-balancer quota headroom"
LIMITS_JSON=$(openstack limits show --absolute -f json)
limit_value() {
  local current_key=$1 legacy_key=$2
  jq -er --arg current "${current_key}" --arg legacy "${legacy_key}" \
    '.[] | select(.Name == $current or .Name == $legacy) | .Value' <<<"${LIMITS_JSON}"
}
required_instances=$(( MAGNUM_MASTER_COUNT + MAGNUM_NODE_COUNT ))
required_cores=$((
  MAGNUM_MASTER_COUNT * $(jq -er '.vcpus' <<<"${MASTER_FLAVOR_JSON}")
  + MAGNUM_NODE_COUNT * $(jq -er '.vcpus' <<<"${WORKER_FLAVOR_JSON}")
))
required_ram=$((
  MAGNUM_MASTER_COUNT * $(jq -er '.ram' <<<"${MASTER_FLAVOR_JSON}")
  + MAGNUM_NODE_COUNT * $(jq -er '.ram' <<<"${WORKER_FLAVOR_JSON}")
))
max_instances=$(limit_value max_total_instances maxTotalInstances)
used_instances=$(limit_value total_instances_used totalInstancesUsed)
max_cores=$(limit_value max_total_cores maxTotalCores)
used_cores=$(limit_value total_cores_used totalCoresUsed)
max_ram=$(limit_value max_total_ram_size maxTotalRAMSize)
used_ram=$(limit_value total_ram_used totalRAMUsed)

check_headroom() {
  local resource=$1 required=$2 used=$3 maximum=$4
  if (( maximum >= 0 && used + required > maximum )); then
    log::die "Insufficient ${resource} quota: need ${required}, available $((maximum - used))"
  fi
}

check_headroom instances "${required_instances}" "${used_instances}" "${max_instances}"
check_headroom cores "${required_cores}" "${used_cores}" "${max_cores}"
check_headroom RAM-MiB "${required_ram}" "${used_ram}" "${max_ram}"

QUOTA_JSON=$(openstack quota show -f json)
quota_limit() {
  local resource=$1
  jq -er --arg resource "${resource}" \
    '.[] | select(.Resource == $resource) | .Limit' <<<"${QUOTA_JSON}"
}
resource_count() {
  openstack "$@" list --project "${PROJECT_ID}" -f json | jq 'length'
}

check_headroom networks 1 "$(resource_count network)" "$(quota_limit networks)"
check_headroom subnets 1 "$(resource_count subnet)" "$(quota_limit subnets)"
check_headroom routers 1 "$(resource_count router)" "$(quota_limit routers)"
check_headroom ports "$((required_instances + 5))" "$(resource_count port)" "$(quota_limit ports)"
check_headroom floating-ips 1 "$(resource_count floating ip)" "$(quota_limit floating_ips)"
check_headroom security-groups 2 "$(resource_count security group)" "$(quota_limit security_groups)"

LB_QUOTA_JSON=$(openstack loadbalancer quota show "${PROJECT_ID}" -f json) \
  || log::die "Unable to read load-balancer quota"
max_loadbalancers=$(jq -er '.load_balancer // .load_balancers // ."Load Balancer"' \
  <<<"${LB_QUOTA_JSON}")
used_loadbalancers=$(openstack loadbalancer list --project "${PROJECT_ID}" -f json | jq 'length')
check_headroom load-balancers 1 "${used_loadbalancers}" "${max_loadbalancers}"

log::step 5 "Checking cluster-name ownership"
mapfile -t MATCHING_CLUSTER_IDS < <(os::cluster_ids_by_name "${MAGNUM_CLUSTER_NAME}")
if (( ${#MATCHING_CLUSTER_IDS[@]} > 1 )); then
  log::die "Multiple Magnum clusters are named '${MAGNUM_CLUSTER_NAME}'; UUID ownership is ambiguous"
fi
if (( ${#MATCHING_CLUSTER_IDS[@]} == 1 )); then
  [[ -f "${STATE_FILE}" ]] \
    || log::die "Cluster name '${MAGNUM_CLUSTER_NAME}' already exists but is not owned by this bootstrap"
  OWNED_CLUSTER_ID=$(os::verify_owned_cluster "${STATE_FILE}" "${MAGNUM_CLUSTER_NAME}")
  [[ "${OWNED_CLUSTER_ID}" == "${MATCHING_CLUSTER_IDS[0]}" ]] \
    || log::die "Existing cluster does not match bootstrap ownership state"
  log::info "Existing owned cluster: ${OWNED_CLUSTER_ID}"
elif [[ -f "${STATE_FILE}" ]]; then
  log::die "Ownership state exists but '${MAGNUM_CLUSTER_NAME}' is not visible; inspect ${STATE_FILE}"
fi

log::success "Preflight passed for project ${PROJECT_ID}"
log::info "  template : ${MAGNUM_TEMPLATE_NAME} (${MAGNUM_TEMPLATE_ID})"
log::info "  image    : ${IMAGE_NAME}"
log::info "  keypair  : ${MAGNUM_KEYPAIR}"
log::info "  cluster  : ${MAGNUM_CLUSTER_NAME}"
