#!/usr/bin/env bash
# Read-only validation for Magnum management-cluster prerequisites.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/openstack.bash"
source "${REPO_ROOT}/scripts/lib/credentials.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
csoc::load_profile "${REPO_ROOT}"

STATE_FILE="${MAGNUM_STATE_FILE:-${REPO_ROOT}/.state/magnum-cluster.json}"
STATE_DIR=$(dirname "${STATE_FILE}")
KUBECONFIG_DIR="${MAGNUM_KUBECONFIG_DIR:-${HOME}/.kube}"
MAGNUM_CREDENTIAL_FILE=$(credentials::magnum_file)
RUNTIME_CREDENTIAL_FILE=$(credentials::runtime_file)
VALIDATE_RUNTIME_CREDENTIAL=false
if [[ "${CSOC_FLEET_ENABLED}" == true || -f "${RUNTIME_CREDENTIAL_FILE}" ]]; then
  VALIDATE_RUNTIME_CREDENTIAL=true
fi

for required_command in git openstack jq; do
  command -v "${required_command}" >/dev/null 2>&1 \
    || log::die "Required command not found: ${required_command}"
done

(( MAGNUM_MASTER_COUNT == 1 || MAGNUM_MASTER_COUNT == 3 )) \
  || log::die "Magnum control plane must contain either 1 development or 3 HA members"
(( MAGNUM_EXPECTED_INITIAL_NODES == MAGNUM_MASTER_COUNT + MAGNUM_NODE_COUNT )) \
  || log::die "Expected initial node count does not match immutable masters plus initial workers"
if [[ "${CSOC_PROFILE}" == prod ]]; then
  [[ "${CSOC_FLEET_ENABLED}" == false ]] \
    || log::die "Production fleet must remain disabled"
  for repository_revision in \
    "${REPO_ROOT}:${CSOC_BOOTSTRAP_REVISION}" \
    "${REPO_ROOT}/../js-poc-csoc-app-catalog:${CSOC_CATALOG_REVISION}"; do
    repository=${repository_revision%:*}
    revision=${repository_revision##*:}
    git -C "${repository}" ls-remote --exit-code --heads origin \
      "refs/heads/${revision}" >/dev/null \
      || log::die "Production release branch is unavailable: ${repository}@${revision}"
  done
fi

log::step 1 "Checking separated OpenStack credentials and local state paths"
credentials::require_private_file "${MAGNUM_CREDENTIAL_FILE}" Magnum
MAGNUM_CREDENTIAL_JSON=$(credentials::metadata "${MAGNUM_CREDENTIAL_FILE}" "${OS_CLOUD}")
credentials::require_unexpired_if_set "${MAGNUM_CREDENTIAL_JSON}" Magnum
[[ $(jq -r '.project_id' <<<"${MAGNUM_CREDENTIAL_JSON}") == "${MAGNUM_PROJECT_ID}" \
   && $(jq -r '.app_project_id' <<<"${MAGNUM_CREDENTIAL_JSON}") == "${MAGNUM_PROJECT_ID}" ]] \
  || log::die "Magnum credential is not scoped to expected project ${MAGNUM_PROJECT_ID}"
[[ $(jq -r '.unrestricted' <<<"${MAGNUM_CREDENTIAL_JSON}") == true ]] \
  || log::die "Magnum application credential must be unrestricted for trustee/trust creation"
if [[ "${VALIDATE_RUNTIME_CREDENTIAL}" == true ]]; then
  credentials::require_private_file "${RUNTIME_CREDENTIAL_FILE}" Runtime
  RUNTIME_CREDENTIAL_JSON=$(credentials::metadata "${RUNTIME_CREDENTIAL_FILE}" "${OS_CLOUD}")
  credentials::require_unexpired "${RUNTIME_CREDENTIAL_JSON}" Runtime
  [[ $(jq -r '.project_id' <<<"${RUNTIME_CREDENTIAL_JSON}") == "${MAGNUM_PROJECT_ID}" \
     && $(jq -r '.app_project_id' <<<"${RUNTIME_CREDENTIAL_JSON}") == "${MAGNUM_PROJECT_ID}" ]] \
    || log::die "Runtime credential is not scoped to expected project ${MAGNUM_PROJECT_ID}"
  [[ $(jq -r '.unrestricted' <<<"${RUNTIME_CREDENTIAL_JSON}") == false ]] \
    || log::die "Runtime CAPO/workload application credential must be restricted"
  [[ $(jq -r '.id' <<<"${MAGNUM_CREDENTIAL_JSON}") != \
     $(jq -r '.id' <<<"${RUNTIME_CREDENTIAL_JSON}") ]] \
    || log::die "Magnum and runtime credentials must be distinct"
else
  log::info "${CSOC_PROFILE} has no fleet; no runtime credential is required"
fi
mkdir -p "${STATE_DIR}" "${KUBECONFIG_DIR}"
chmod 700 "${STATE_DIR}" "${KUBECONFIG_DIR}"
[[ -w "${STATE_DIR}" && -w "${KUBECONFIG_DIR}" ]] \
  || log::die "State and kubeconfig directories must be writable"
credentials::configure_magnum
PROJECT_ID=$(openstack token issue -f value -c project_id)
[[ "${PROJECT_ID}" == "${MAGNUM_PROJECT_ID}" ]] \
  || log::die "Authenticated project changed during preflight"

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
[[ $(jq -r '.network_driver' <<<"${TEMPLATE_JSON}") == "calico" ]] \
  || log::die "Selected template does not use the required Calico network driver"

IMAGE_NAME=$(jq -r '.image_id' <<<"${TEMPLATE_JSON}")
IMAGE_JSON=$(openstack image show "${IMAGE_NAME}" -f json) \
  || log::die "Template image is unavailable: ${IMAGE_NAME}"
[[ $(jq -r '.status' <<<"${IMAGE_JSON}") == "active" ]] \
  || log::die "Template image is not active: ${IMAGE_NAME}"
[[ $(jq -r '.id' <<<"${IMAGE_JSON}") == "${MAGNUM_IMAGE_ID}" \
   && $(jq -r '.name' <<<"${IMAGE_JSON}") == "${MAGNUM_IMAGE_NAME}" ]] \
  || log::die "Template no longer resolves to expected image ${MAGNUM_IMAGE_NAME} (${MAGNUM_IMAGE_ID})"
IMAGE_MIN_DISK_GIB=$(jq -er '(.min_disk // 0) | tonumber' <<<"${IMAGE_JSON}") \
  || log::die "Template image min_disk is not numeric"
IMAGE_VIRTUAL_SIZE_BYTES=$(jq -er '(.virtual_size // .size // 0) | tonumber' <<<"${IMAGE_JSON}") \
  || log::die "Template image size is not numeric"
IMAGE_VIRTUAL_SIZE_GIB=$(( (IMAGE_VIRTUAL_SIZE_BYTES + 1073741823) / 1073741824 ))
IMAGE_REQUIRED_DISK_GIB=${IMAGE_MIN_DISK_GIB}
(( IMAGE_VIRTUAL_SIZE_GIB > IMAGE_REQUIRED_DISK_GIB )) \
  && IMAGE_REQUIRED_DISK_GIB=${IMAGE_VIRTUAL_SIZE_GIB}
[[ "${MAGNUM_BOOT_VOLUME_SIZE}" =~ ^[1-9][0-9]*$ ]] \
  || log::die "Boot volume size must be a positive integer GiB value"
(( MAGNUM_BOOT_VOLUME_SIZE >= IMAGE_REQUIRED_DISK_GIB )) \
  || log::die "Boot volume ${MAGNUM_BOOT_VOLUME_SIZE} GiB is smaller than image floor ${IMAGE_REQUIRED_DISK_GIB} GiB"

log::step 3 "Validating network, flavors, keypair, and load balancer service"
[[ "${MAGNUM_FLOATING_IP_ENABLED}" == true && "${MAGNUM_MASTER_LB_ENABLED}" == true ]] \
  || log::die "Guide-exact provisioning requires a floating IP and master load balancer"
NETWORK_JSON=$(openstack network show "${MAGNUM_EXTERNAL_NETWORK}" -f json) \
  || log::die "External network is unavailable: ${MAGNUM_EXTERNAL_NETWORK}"
[[ $(jq -r '."router:external"' <<<"${NETWORK_JSON}") == "true" ]] \
  || log::die "Network is not external: ${MAGNUM_EXTERNAL_NETWORK}"
[[ $(jq -r '.id' <<<"${NETWORK_JSON}") == "${MAGNUM_EXTERNAL_NETWORK_ID}" ]] \
  || log::die "External network UUID changed"
FIXED_NETWORK_JSON=$(openstack network show "${MAGNUM_FIXED_NETWORK}" -f json) \
  || log::die "Fixed network is unavailable: ${MAGNUM_FIXED_NETWORK}"
FIXED_SUBNET_JSON=$(openstack subnet show "${MAGNUM_FIXED_SUBNET}" -f json) \
  || log::die "Fixed subnet is unavailable: ${MAGNUM_FIXED_SUBNET}"
[[ $(jq -r '.id' <<<"${FIXED_NETWORK_JSON}") == "${MAGNUM_FIXED_NETWORK_ID}" ]] \
  || log::die "Fixed network UUID changed"
[[ $(jq -r '.id' <<<"${FIXED_SUBNET_JSON}") == "${MAGNUM_FIXED_SUBNET_ID}" \
   && $(jq -r '.network_id' <<<"${FIXED_SUBNET_JSON}") == "${MAGNUM_FIXED_NETWORK_ID}" \
   && $(jq -r '.ip_version' <<<"${FIXED_SUBNET_JSON}") == 4 ]] \
  || log::die "Fixed subnet no longer matches the expected IPv4 network"
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
VOLUME_SUMMARY_JSON=$(openstack volume summary -f json)
used_volumes=$(jq -er '."Total Count" // .total_count' <<<"${VOLUME_SUMMARY_JSON}")
used_gigabytes=$(jq -er '."Total Size" // .total_size' <<<"${VOLUME_SUMMARY_JSON}")
check_headroom volumes "${required_instances}" "${used_volumes}" "$(quota_limit volumes)"
check_headroom volume-gigabytes "$((required_instances * MAGNUM_BOOT_VOLUME_SIZE))" \
  "${used_gigabytes}" "$(quota_limit gigabytes)"

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
  OWNED_CLUSTER_JSON=$(openstack coe cluster show "${OWNED_CLUSTER_ID}" -f json)
  [[ $(jq -r '.master_count' <<<"${OWNED_CLUSTER_JSON}") == "${MAGNUM_MASTER_COUNT}" \
     && $(jq -r '.master_flavor_id' <<<"${OWNED_CLUSTER_JSON}") == "${MAGNUM_MASTER_FLAVOR}" ]] \
    || log::die "Owned cluster control plane differs from immutable ${CSOC_PROFILE} profile (${MAGNUM_MASTER_COUNT} x ${MAGNUM_MASTER_FLAVOR})"
  log::info "Existing owned cluster: ${OWNED_CLUSTER_ID}"
elif [[ -f "${STATE_FILE}" ]]; then
  log::die "Ownership state exists but '${MAGNUM_CLUSTER_NAME}' is not visible; inspect ${STATE_FILE}"
fi

log::success "Preflight passed for project ${PROJECT_ID}"
log::info "  template : ${MAGNUM_TEMPLATE_NAME} (${MAGNUM_TEMPLATE_ID})"
log::info "  image    : ${IMAGE_NAME}"
log::info "  root disk: ${MAGNUM_BOOT_VOLUME_SIZE} GiB (image floor ${IMAGE_REQUIRED_DISK_GIB} GiB)"
log::info "  keypair  : ${MAGNUM_KEYPAIR}"
log::info "  cluster  : ${MAGNUM_CLUSTER_NAME}"
log::info "  profile  : ${CSOC_PROFILE} (${MAGNUM_MASTER_COUNT} x ${MAGNUM_MASTER_FLAVOR} control plane)"
