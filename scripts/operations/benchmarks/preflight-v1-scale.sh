#!/usr/bin/env bash
# Read-only quota, ownership, credential, name, and CIDR gate for the v1 benchmark.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
FLEET_ROOT="${FLEET_ROOT:-${WORKSPACE_ROOT}/js-poc-csoc-fleet}"
INVENTORY="${BENCHMARK_INVENTORY:-${FLEET_ROOT}/accounts/staging/benchmarks/v1-scale/inventory.yaml}"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/logging.bash"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/credentials.bash"

phase=${1:-}
[[ "${phase}" == single || "${phase}" == batch ]] || {
  echo "usage: $0 single|batch" >&2
  exit 64
}
for command_name in openstack yq jq rg stat; do
  command -v "${command_name}" >/dev/null 2>&1 || log::die "Required command not found: ${command_name}"
done
[[ -f "${INVENTORY}" ]] || log::die "Benchmark inventory not found: ${INVENTORY}"

project_id=$(yq -er '.spec.projectID' "${INVENTORY}")
mapfile -t phase_accounts < <(
  PHASE="${phase}" yq -r '.spec.spokes[] | select(.phase == strenv(PHASE)) | .account' "${INVENTORY}"
)
mapfile -t phase_spokes < <(
  PHASE="${phase}" yq -r '.spec.spokes[] | select(.phase == strenv(PHASE)) | .name' "${INVENTORY}"
)

credential_root=/run/csoc-credentials/accounts
[[ -d "${credential_root}" ]] || credential_root="${REPO_ROOT}/scripts/host/credentials/accounts"
declare -A credential_ids=()
for account in "${phase_accounts[@]}"; do
  credential="${credential_root}/${account}/clouds.yaml"
  credential_metadata=
  [[ -f "${credential}" && $(stat -c '%a' "${credential}") == 600 ]] \
    || log::die "Missing mode-0600 credential for ${account}"
  credential_metadata=$(credentials::metadata "${credential}" openstack)
  credentials::require_unexpired "${credential_metadata}" "${account} benchmark"
  credential_project=$(jq -er '.project_id' <<<"${credential_metadata}")
  credential_id=$(jq -er '.id' <<<"${credential_metadata}")
  yq -e '.clouds.openstack.auth.application_credential_secret | length > 0' "${credential}" >/dev/null \
    || log::die "Credential secret is absent for ${account}"
  [[ "${credential_project}" == "${project_id}" ]] || log::die "Credential project mismatch for ${account}"
  [[ $(jq -r '.app_project_id == .project_id and .unrestricted == false' \
      <<<"${credential_metadata}") == true ]] \
    || log::die "Credential for ${account} must be restricted to ${project_id}"
  [[ -z "${credential_ids[${credential_id}]:-}" ]] || log::die "Application credential is reused by two benchmark accounts"
  credential_ids[${credential_id}]=${account}
done

export OS_CLIENT_CONFIG_FILE="${credential_root}/${phase_accounts[0]}/clouds.yaml"
export OS_CLOUD=${OS_CLOUD:-openstack}
auth_project=$(openstack token issue -f json | jq -er '.project_id // .project.id // .Project_ID')
[[ "${auth_project}" == "${project_id}" ]] || log::die "Authenticated OpenStack project mismatch"

log::step 1 "Checking benchmark ownership, names, and CIDRs"
for account in "${phase_accounts[@]}"; do
  matches=$(ACCOUNT="${account}" yq -r \
    '[.assignments[] | select(.account == strenv(ACCOUNT) and .app == "kubernetes" and .environment == "dev" and .owner == "staging")] | length' \
    "${FLEET_ROOT}/ownership.yaml")
  [[ "${matches}" == 1 ]] || log::die "Ownership is not unique for ${account}/kubernetes/dev"
done

servers=$(openstack server list -f json)
networks=$(openstack network list --project "${project_id}" -f json)
subnets=$(openstack subnet list --project "${project_id}" -f json)
loadbalancers=$(openstack loadbalancer list --project "${project_id}" -f json)
for spoke in "${phase_spokes[@]}"; do
  jq -e --arg name "${spoke}" 'all(.[]; ((.Name // .name // "") | startswith($name)) | not)' \
    <<<"${servers}" >/dev/null || log::die "Server name already exists for ${spoke}"
  jq -e --arg name "csoc-${spoke}" 'all(.[]; (.Name // .name // "") != $name)' \
    <<<"${networks}" >/dev/null || log::die "Network name already exists for ${spoke}"
  cidr=$(NAME="${spoke}" yq -r '.spec.spokes[] | select(.name == strenv(NAME)) | .nodeCIDR' "${INVENTORY}")
  jq -e --arg cidr "${cidr}" 'all(.[]; (.Subnet // .subnet // .CIDR // .cidr // "") != $cidr)' \
    <<<"${subnets}" >/dev/null || log::die "Subnet CIDR already exists: ${cidr}"
done

log::step 2 "Checking compute, network, volume, and load-balancer headroom"
control_planes=$(PHASE="${phase}" yq -r \
  '.spec.spokes[] | select(.phase == strenv(PHASE)) | .controlPlanes' "${INVENTORY}" \
  | awk '{total += $1} END {print total + 0}')
workers=$(PHASE="${phase}" yq -r \
  '.spec.spokes[] | select(.phase == strenv(PHASE)) | .minWorkers' "${INVENTORY}" \
  | awk '{total += $1} END {print total + 0}')
required_instances=$((control_planes + workers))
cp_flavor=$(openstack flavor show "$(yq -r '.spec.controlPlaneFlavor' "${INVENTORY}")" -f json)
worker_flavor=$(openstack flavor show "$(yq -r '.spec.workerFlavor' "${INVENTORY}")" -f json)
required_cores=$((control_planes * $(jq -er '.vcpus' <<<"${cp_flavor}") + workers * $(jq -er '.vcpus' <<<"${worker_flavor}")))
required_ram=$((control_planes * $(jq -er '.ram' <<<"${cp_flavor}") + workers * $(jq -er '.ram' <<<"${worker_flavor}")))
limits=$(openstack limits show --absolute -f json)
limit_value() {
  jq -er --arg current "$1" --arg legacy "$2" '.[] | select(.Name == $current or .Name == $legacy) | .Value' <<<"${limits}"
}
check_headroom() {
  local label=$1 required=$2 used=$3 maximum=$4
  (( maximum < 0 || used + required <= maximum )) \
    || log::die "Insufficient ${label}: need ${required}, available $((maximum-used))"
}
check_headroom instances "${required_instances}" "$(limit_value total_instances_used totalInstancesUsed)" "$(limit_value max_total_instances maxTotalInstances)"
check_headroom cores "${required_cores}" "$(limit_value total_cores_used totalCoresUsed)" "$(limit_value max_total_cores maxTotalCores)"
check_headroom RAM-MiB "${required_ram}" "$(limit_value total_ram_used totalRAMUsed)" "$(limit_value max_total_ram_size maxTotalRAMSize)"

quota=$(openstack quota show -f json)
quota_limit() { jq -er --arg resource "$1" '.[] | select(.Resource == $resource) | .Limit' <<<"${quota}"; }
network_count=$(jq 'length' <<<"${networks}")
subnet_count=$(jq 'length' <<<"${subnets}")
port_count=$(openstack port list --project "${project_id}" -f json | jq 'length')
security_group_count=$(openstack security group list --project "${project_id}" -f json | jq 'length')
expected_spokes=${#phase_spokes[@]}
check_headroom networks "${expected_spokes}" "${network_count}" "$(quota_limit networks)"
check_headroom subnets "${expected_spokes}" "${subnet_count}" "$(quota_limit subnets)"
check_headroom ports "$((required_instances + expected_spokes * 2))" "${port_count}" "$(quota_limit ports)"
check_headroom security-groups "$((expected_spokes * 2))" "${security_group_count}" "$(quota_limit security_groups)"

volume_summary=$(openstack volume summary -f json)
used_volumes=$(jq -er '."Total Count" // .total_count' <<<"${volume_summary}")
used_gib=$(jq -er '."Total Size" // .total_size' <<<"${volume_summary}")
check_headroom volumes "${required_instances}" "${used_volumes}" "$(quota_limit volumes)"
check_headroom volume-GiB "$((required_instances * 20))" "${used_gib}" "$(quota_limit gigabytes)"

lb_quota=$(openstack loadbalancer quota show "${project_id}" -f json)
max_lbs=$(jq -er '.load_balancer // .load_balancers // ."Load Balancer"' <<<"${lb_quota}")
check_headroom load-balancers "${expected_spokes}" "$(jq 'length' <<<"${loadbalancers}")" "${max_lbs}"

log::success "${phase} benchmark preflight passed for ${required_instances} servers and $((required_instances * 20)) GiB of roots"
