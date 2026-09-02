#!/usr/bin/env bash
# Read-only provider and quota preflight for a rendered v2 spoke package.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/credentials.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
csoc::load_profile "${REPO_ROOT}"

[[ "${CSOC_V2_LIVE_PREFLIGHT_APPROVED:-false}" == true ]] || {
  echo "set CSOC_V2_LIVE_PREFLIGHT_APPROVED=true for the selected non-production CSOC" >&2
  exit 1
}
[[ "${CSOC_API_GENERATION}" == v2 && "${CSOC_FLEET_ENABLED}" == true ]] || {
  echo "v2 spoke preflight requires a fleet-enabled v2 profile" >&2
  exit 1
}
manifest=${1:?usage: preflight-v2-spoke.sh RENDERED-YAML CAPACITY-VALIDATOR}
capacity_validator=${2:?usage: preflight-v2-spoke.sh RENDERED-YAML CAPACITY-VALIDATOR}
[[ -f "${manifest}" && -f "${capacity_validator}" ]] || {
  echo "rendered manifest or capacity validator is unavailable" >&2
  exit 1
}
for command_name in jq kubectl openstack yq; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "missing ${command_name}" >&2; exit 1; }
done

existing=$(kubectl get workloadclusters.infra.csoc.js2.org --all-namespaces \
  --ignore-not-found -o name 2>/dev/null || true)
initial_headroom=true
if [[ -n "${existing}" ]]; then
  initial_headroom=false
  echo "existing v2 WorkloadCluster detected; validating absolute quota and provider contracts for idempotent replay" >&2
fi

credentials::configure_magnum
project_id=$(openstack token issue -f value -c project_id)
while IFS= read -r declared_project; do
  [[ "${declared_project}" == "${project_id}" ]] || {
    echo "SpokeAccount project ${declared_project} does not match authenticated project ${project_id}" >&2
    exit 1
  }
done < <(yq eval-all -r 'select(.kind == "SpokeAccount") | .spec.projectID' "${manifest}" | sort -u)

while IFS=$'\t' read -r flavor_id vcpus ram image_id volume_type failure_domain; do
  flavor=$(openstack flavor show "${flavor_id}" -f json)
  [[ $(jq -r '.id' <<<"${flavor}") == "${flavor_id}" \
     && $(jq -r '.vcpus' <<<"${flavor}") == "${vcpus}" \
     && $(jq -r '.ram' <<<"${flavor}") == "${ram}" ]] || {
    echo "MachineProfile flavor contract changed for ${flavor_id}" >&2
    exit 1
  }
  image=$(openstack image show "${image_id}" -f json)
  [[ $(jq -r '.id' <<<"${image}") == "${image_id}" \
     && $(jq -r '.status' <<<"${image}") == active ]] || {
    echo "MachineProfile image is missing or inactive: ${image_id}" >&2
    exit 1
  }
  [[ $(openstack volume type show "${volume_type}" -f json | jq -r '.id') == "${volume_type}" ]] \
    || { echo "MachineProfile volume type is unavailable: ${volume_type}" >&2; exit 1; }
  openstack availability zone list --compute -f json \
    | jq -e --arg zone "${failure_domain}" \
      'any(.[]; (."Zone Name" // .zoneName // .name) == $zone and ((."Zone Status" // .zoneState.available // true) != false))' \
      >/dev/null || { echo "compute failure domain is unavailable: ${failure_domain}" >&2; exit 1; }
done < <(yq eval-all -r '
  select(.kind == "MachineProfile") |
  [.spec.flavorID,.spec.vCPUs,.spec.ramMiB,.spec.imageID,.spec.volumeTypeID,.spec.failureDomain] | @tsv
' "${manifest}" | sort -u)

while IFS= read -r network_id; do
  network=$(openstack network show "${network_id}" -f json)
  [[ $(jq -r '.id' <<<"${network}") == "${network_id}" \
     && $(jq -r '."router:external"' <<<"${network}") == true ]] || {
    echo "SpokeAccount external network is unavailable or not external: ${network_id}" >&2
    exit 1
  }
done < <(yq eval-all -r 'select(.kind == "SpokeAccount") | .spec.externalNetworkID' "${manifest}" | sort -u)

limits=$(openstack limits show --absolute -f json)
quota=$(openstack quota show -f json)
volume_summary=$(openstack volume summary -f json)
limit_value() {
  local current=$1 legacy=$2
  jq -er --arg current "${current}" --arg legacy "${legacy}" \
    '.[] | select(.Name == $current or .Name == $legacy) | .Value' <<<"${limits}"
}
quota_limit() {
  local resource=$1
  jq -er --arg resource "${resource}" '.[] | select(.Resource == $resource) | .Limit' <<<"${quota}"
}
check_headroom() {
  local resource=$1 required=$2 used=$3 limit=$4
  if (( limit >= 0 && used + required > limit )); then
    echo "insufficient ${resource} quota: need ${required}, available $((limit - used))" >&2
    exit 1
  fi
}
if [[ "${initial_headroom}" == true ]]; then
  max_instances=$(yq -o=json '.' "${manifest}" \
    | jq -s '[.[] | select(.kind == "SpokeAccount") | .spec.capacityBudget.maxInstances] | add')
  resource_count() { openstack "$@" list --project "${project_id}" -f json | jq 'length'; }
  check_headroom networks 1 "$(resource_count network)" "$(quota_limit networks)"
  check_headroom subnets 1 "$(resource_count subnet)" "$(quota_limit subnets)"
  check_headroom routers 1 "$(resource_count router)" "$(quota_limit routers)"
  check_headroom ports "$((max_instances + 5))" "$(resource_count port)" "$(quota_limit ports)"
  check_headroom floating-ips 1 "$(resource_count floating ip)" "$(quota_limit floating_ips)"
  check_headroom security-groups 2 "$(resource_count security group)" "$(quota_limit security_groups)"
  lb_quota=$(openstack loadbalancer quota show "${project_id}" -f json)
  lb_limit=$(jq -er '.load_balancer // .load_balancers // ."Load Balancer"' <<<"${lb_quota}")
  lb_used=$(openstack loadbalancer list --project "${project_id}" -f json | jq 'length')
  check_headroom load-balancers 1 "${lb_used}" "${lb_limit}"
fi
live_quota=$(mktemp)
trap 'rm -f -- "${live_quota}"' EXIT HUP INT TERM
cores_used=$(limit_value total_cores_used totalCoresUsed)
ram_used=$(limit_value total_ram_used totalRAMUsed)
instances_used=$(limit_value total_instances_used totalInstancesUsed)
volumes_used=$(jq -er '."Total Count" // .total_count' <<<"${volume_summary}")
gigabytes_used=$(jq -er '."Total Size" // .total_size' <<<"${volume_summary}")
if [[ "${initial_headroom}" == false ]]; then
  cores_used=0
  ram_used=0
  instances_used=0
  volumes_used=0
  gigabytes_used=0
fi
jq -n \
  --argjson cores_limit "$(limit_value max_total_cores maxTotalCores)" \
  --argjson cores_used "${cores_used}" \
  --argjson ram_limit "$(limit_value max_total_ram_size maxTotalRAMSize)" \
  --argjson ram_used "${ram_used}" \
  --argjson instances_limit "$(limit_value max_total_instances maxTotalInstances)" \
  --argjson instances_used "${instances_used}" \
  --argjson volumes_limit "$(quota_limit volumes)" \
  --argjson volumes_used "${volumes_used}" \
  --argjson gigabytes_limit "$(quota_limit gigabytes)" \
  --argjson gigabytes_used "${gigabytes_used}" \
  '{compute:{cores:{limit:$cores_limit,in_use:$cores_used},ramMiB:{limit:$ram_limit,in_use:$ram_used},instances:{limit:$instances_limit,in_use:$instances_used}},volume:{volumes:{limit:$volumes_limit,in_use:$volumes_used},gigabytes:{limit:$gigabytes_limit,in_use:$gigabytes_used}}}' \
  >"${live_quota}"
bash "${capacity_validator}" "${manifest}" "${live_quota}"

echo "live v2 provider and capacity preflight passed for project ${project_id} (initialHeadroom=${initial_headroom})"
