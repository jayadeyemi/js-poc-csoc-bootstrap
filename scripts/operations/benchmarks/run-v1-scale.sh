#!/usr/bin/env bash
# Time one or ten v1 spokes through real OpenStack and Kubernetes readiness.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
FLEET_ROOT="${FLEET_ROOT:-${WORKSPACE_ROOT}/js-poc-csoc-fleet}"
INVENTORY="${BENCHMARK_INVENTORY:-${FLEET_ROOT}/accounts/staging/benchmarks/v1-scale/inventory.yaml}"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/logging.bash"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
export CSOC_PROFILE=staging
csoc::load_profile "${REPO_ROOT}"
export KUBECONFIG="${KUBECONFIG:-${MAGNUM_KUBECONFIG_DIR}/config}"
export OS_CLOUD="${OS_CLOUD:-openstack}"

phase=
evidence_dir=
resume=false
usage() {
  printf 'Usage: %s --phase single|batch [--evidence-dir DIR | --resume-evidence DIR]\n' "$0" >&2
  exit 64
}
while (( $# > 0 )); do
  case "$1" in
    --phase)
      (( $# >= 2 )) || usage
      phase=$2
      shift 2
      ;;
    --evidence-dir)
      (( $# >= 2 )) || usage
      [[ -z "${evidence_dir}" ]] || usage
      evidence_dir=$2
      shift 2
      ;;
    --resume-evidence)
      (( $# >= 2 )) || usage
      [[ -z "${evidence_dir}" ]] || usage
      evidence_dir=$2
      resume=true
      shift 2
      ;;
    *) usage ;;
  esac
done
[[ "${phase}" == single || "${phase}" == batch ]] || usage
[[ -f "${INVENTORY}" ]] || log::die "Benchmark inventory not found: ${INVENTORY}"

for command_name in kubectl argocd openstack yq jq date sort awk realpath flock; do
  command -v "${command_name}" >/dev/null 2>&1     || log::die "Required command not found: ${command_name}"
done

credential_account=scale-00
[[ "${phase}" == single ]] || credential_account=scale-01
if [[ -z "${OS_CLIENT_CONFIG_FILE:-}" ]]; then
  if [[ -f "/run/csoc-credentials/accounts/${credential_account}/clouds.yaml" ]]; then
    OS_CLIENT_CONFIG_FILE="/run/csoc-credentials/accounts/${credential_account}/clouds.yaml"
  else
    OS_CLIENT_CONFIG_FILE="${REPO_ROOT}/scripts/host/credentials/accounts/${credential_account}/clouds.yaml"
  fi
fi
export OS_CLIENT_CONFIG_FILE
[[ -f "${OS_CLIENT_CONFIG_FILE}" ]]   || log::die "Restricted runtime credential is unavailable for ${credential_account}"
[[ "$(stat -c '%a' "${OS_CLIENT_CONFIG_FILE}")" == 600 ]]   || log::die "Runtime credential must have mode 0600"

project_id=$(yq -er '.spec.projectID' "${INVENTORY}")
timeout_seconds=$(yq -er '.spec.timeoutSeconds' "${INVENTORY}")
expected_spokes=$(PHASE="${phase}" yq -r '[.spec.spokes[] | select(.phase == strenv(PHASE))] | length' "${INVENTORY}")
expected_servers=$(yq -er ".spec.expected.${phase}.servers" "${INVENTORY}")
expected_volumes=$(yq -er ".spec.expected.${phase}.volumes" "${INVENTORY}")
expected_lbs=$(yq -er ".spec.expected.${phase}.loadBalancers" "${INVENTORY}")
expected_networks=$(yq -er ".spec.expected.${phase}.networks" "${INVENTORY}")
mapfile -t spoke_names < <(
  PHASE="${phase}" yq -r '.spec.spokes[] | select(.phase == strenv(PHASE)) | .name' "${INVENTORY}"
)
(( ${#spoke_names[@]} == expected_spokes ))   || log::die "Inventory phase count does not match expected count"
expected_node_sum=0
for spoke in "${spoke_names[@]}"; do
  node_count=$(NAME="${spoke}" yq -r '.spec.spokes[] | select(.name == strenv(NAME)) | .controlPlanes + .minWorkers' "${INVENTORY}")
  (( expected_node_sum += node_count ))
done
(( expected_node_sum == expected_servers && expected_volumes == expected_servers && expected_lbs == expected_spokes && expected_networks == expected_spokes )) \
  || log::die "Benchmark expected-resource totals are internally inconsistent"

evidence_root="${REPO_ROOT}/.state/benchmarks/v1-scale"
if [[ "${resume}" == true ]]; then
  [[ -n "${evidence_dir}" && -d "${evidence_dir}" ]] \
    || log::die "--resume-evidence must name an existing evidence directory"
  evidence_dir=$(realpath "${evidence_dir}")
  case "${evidence_dir}" in
    "${evidence_root}"/*) ;;
    *) log::die "Resume evidence must be under ${evidence_root}" ;;
  esac
  [[ -s "${evidence_dir}/events.jsonl" ]] \
    || log::die "Resume evidence is incomplete: events"
  for kind in servers networks subnets loadbalancers volumes; do
    [[ -s "${evidence_dir}/before-${kind}.json" ]] \
      || log::die "Resume evidence is incomplete: before-${kind}"
  done
  [[ ! -e "${evidence_dir}/metrics.json" ]] \
    || log::die "Benchmark evidence is already complete"
else
  # Credential preparation is outside the timer, as are all read-only capacity,
  # ownership, name, and CIDR checks.
  bash "${SCRIPT_DIR}/preflight-v1-scale.sh" "${phase}"
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  evidence_dir=${evidence_dir:-"${evidence_root}/${timestamp}-${phase}"}
  mkdir -p "${evidence_dir}"
fi
chmod 700 "${evidence_dir}"
exec 9>"${evidence_dir}/.runner.lock"
flock -n 9 || log::die "Another verifier is already using ${evidence_dir}"
events_file="${evidence_dir}/events.jsonl"
summary_file="${evidence_dir}/summary.csv"
metrics_file="${evidence_dir}/metrics.json"
[[ "${resume}" == true ]] || : >"${events_file}"

selector="csoc.js2.org/benchmark-phase=${phase}"
# Argo core mode discovers argocd-cm in the kube-context namespace. This is a
# local kubeconfig setting and occurs before T0; all cloud operations remain
# untouched.
kubectl config set-context "$(kubectl config current-context)" --namespace=argocd >/dev/null
application_count=$(kubectl get applications.argoproj.io -n argocd -l "${selector}" -o json   | jq '.items | length')
(( application_count == expected_spokes ))   || log::die "Expected ${expected_spokes} manual Argo Applications for ${phase}, found ${application_count}"

for spoke in "${spoke_names[@]}"; do
  namespace="spokeclusters-${spoke}"
  if [[ "${resume}" == true ]]; then
    kubectl get spokecluster "${spoke}" -n "${namespace}" >/dev/null 2>&1 \
      || log::die "Resume target ${namespace}/${spoke} does not exist"
  elif kubectl get spokecluster "${spoke}" -n "${namespace}" >/dev/null 2>&1; then
    log::die "SpokeCluster ${namespace}/${spoke} already exists; refusing to falsify timing"
  fi
done

snapshot_openstack() {
  local kind
  openstack server list --long -f json     >"${evidence_dir}/latest-servers.json" &&
  openstack network list --project "${project_id}" -f json     >"${evidence_dir}/latest-networks.json" &&
  openstack subnet list --project "${project_id}" -f json     >"${evidence_dir}/latest-subnets.json" &&
  openstack loadbalancer list --project "${project_id}" -f json     >"${evidence_dir}/latest-loadbalancers.json" &&
  openstack volume list --long -f json     >"${evidence_dir}/latest-volumes.json" \
    || return 1
  for kind in servers networks subnets loadbalancers volumes; do
    jq -e 'type == "array"' "${evidence_dir}/latest-${kind}.json" >/dev/null \
      || return 1
  done
}

if [[ "${resume}" == false ]]; then
  log::step 1 "Capturing before inventory for the ${phase} phase"
  snapshot_openstack || log::die "OpenStack inventory failed before the benchmark"
  cp "${evidence_dir}/latest-servers.json" "${evidence_dir}/before-servers.json"
  cp "${evidence_dir}/latest-networks.json" "${evidence_dir}/before-networks.json"
  cp "${evidence_dir}/latest-subnets.json" "${evidence_dir}/before-subnets.json"
  cp "${evidence_dir}/latest-loadbalancers.json" "${evidence_dir}/before-loadbalancers.json"
  cp "${evidence_dir}/latest-volumes.json" "${evidence_dir}/before-volumes.json"

  for spoke in "${spoke_names[@]}"; do
    existing=$(jq --arg name "${spoke}" '[.[] | select(((.Name // .name // "") | startswith($name)))] | length'     "${evidence_dir}/latest-servers.json")
    (( existing == 0 )) || log::die "OpenStack servers already exist for ${spoke}"
  done
fi

declare -A openstack_ready_at=()
declare -A kubernetes_ready_at=()
declare -A expected_node_count=()
for spoke in "${spoke_names[@]}"; do
  expected_node_count["${spoke}"]=$(NAME="${spoke}" yq -r     '.spec.spokes[] | select(.name == strenv(NAME)) | .controlPlanes + .minWorkers' "${INVENTORY}")
done

verify_server_roots() {
  local spoke=$1 server_rows server_id volume_rows volume_id volume_json
  server_rows=$(jq -r --arg name "${spoke}"     '.[] | select(((.Name // .name // "") | startswith($name))) | (.ID // .id)'     "${evidence_dir}/latest-servers.json")
  [[ -n "${server_rows}" ]] || return 1
  while IFS= read -r server_id; do
    volume_rows=$(openstack server volume list "${server_id}" -f json) || return 1
    [[ $(jq 'length' <<<"${volume_rows}") == 1 ]] || return 1
    volume_id=$(jq -er '.[0].ID // .[0].id // .[0]."Volume ID"' <<<"${volume_rows}") || return 1
    volume_json=$(openstack volume show "${volume_id}" -f json) || return 1
    jq -e --arg sid "${server_id}" --arg project "${project_id}" '
      ((.status // .Status) == "in-use") and
      (((.bootable // .Bootable) | tostring | ascii_downcase) == "true") and
      (((.multiattach // .Multiattach // false) | tostring | ascii_downcase) == "false") and
      (((.size // .Size) | tonumber) == 20) and
      ((.attachments // .Attachments) | type == "array") and
      (((.attachments // .Attachments) | length) == 1) and
      (((.attachments // .Attachments)[0].server_id //
         (.attachments // .Attachments)[0].serverId //
         (.attachments // .Attachments)[0].server) == $sid) and
      (((."os-vol-tenant-attr:tenant_id" // .project_id // .Project // $project) | tostring) == $project)
    ' <<<"${volume_json}" >/dev/null || return 1
  done <<<"${server_rows}"
}

spoke_openstack_ready() {
  local spoke=$1 expected=${expected_node_count[$1]} namespace lb_id
  local servers active networks subnets lbs
  servers=$(jq --arg name "${spoke}" '[.[] | select(((.Name // .name // "") | startswith($name)))] | length'     "${evidence_dir}/latest-servers.json")
  active=$(jq --arg name "${spoke}" '[.[] | select(((.Name // .name // "") | startswith($name)) and
    ((.Status // .status // "") == "ACTIVE"))] | length' "${evidence_dir}/latest-servers.json")
  networks=$(jq --arg name "csoc-${spoke}" '[.[] | select((.Name // .name // "") == $name)] | length'     "${evidence_dir}/latest-networks.json")
  subnets=$(jq --arg name "csoc-${spoke}" '[.[] | select((.Name // .name // "") == $name)] | length'     "${evidence_dir}/latest-subnets.json")
  namespace="spokeclusters-${spoke}"
  lb_id=$(kubectl get openstackcluster "${spoke}" -n "${namespace}" -o json 2>/dev/null \
    | jq -r '.status.apiServerLoadBalancer.id // empty')
  [[ -n "${lb_id}" ]] || return 1
  lbs=$(jq --arg id "${lb_id}" '[.[] | select(
    ((.ID // .Id // .id // "") == $id) and
    ((.provisioning_status // ."Provisioning Status" // "") == "ACTIVE") and
    ((.operating_status // ."Operating Status" // "") == "ONLINE"))] | length'     "${evidence_dir}/latest-loadbalancers.json")
  (( servers == expected && active == expected && networks == 1 && subnets == 1 && lbs == 1 ))     && verify_server_roots "${spoke}"
}

spoke_kubernetes_ready() {
  local spoke=$1 namespace min_workers control_planes
  namespace="spokeclusters-${spoke}"
  min_workers=$(NAME="${spoke}" yq -r     '.spec.spokes[] | select(.name == strenv(NAME)) | .minWorkers' "${INVENTORY}")
  control_planes=$(NAME="${spoke}" yq -r     '.spec.spokes[] | select(.name == strenv(NAME)) | .controlPlanes' "${INVENTORY}")
  [[ $(kubectl get spokecluster "${spoke}" -n "${namespace}" -o json 2>/dev/null       | jq -r '.status.ready // false') == true ]] &&
  [[ $(kubectl get spokecluster "${spoke}" -n "${namespace}" -o json 2>/dev/null       | jq -r '[.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length') -ge 1 ]] &&
  [[ $(kubectl get cluster "${spoke}" -n "${namespace}" -o json 2>/dev/null       | jq -r '[.status.conditions[]? | select((.type == "Available" or .type == "Ready") and .status == "True")] | length') -ge 1 ]] &&
  (( $(kubectl get kubeadmcontrolplane "${spoke}-control-plane" -n "${namespace}" -o json 2>/dev/null       | jq -r '.status.readyReplicas // 0') >= control_planes )) &&
  (( $(kubectl get machinedeployment "${spoke}-workers" -n "${namespace}" -o json 2>/dev/null       | jq -r '.status.readyReplicas // 0') >= min_workers ))
}

capture_diagnostics() {
  kubectl get resourcegraphdefinitions -o yaml >"${evidence_dir}/rgds.yaml" 2>/dev/null || true
  kubectl get spokeclusters,clusters,machines,machinedeployments,kubeadmcontrolplanes -A -o yaml     >"${evidence_dir}/kubernetes.yaml" 2>/dev/null || true
  kubectl get applications -n argocd -l "csoc.js2.org/benchmark=v1-scale" -o yaml     >"${evidence_dir}/applications.yaml" 2>/dev/null || true
  for target in kro-system/kro orc-system/orc-controller-manager     capi-system/capi-controller-manager capo-system/capo-controller-manager     capi-kubeadm-bootstrap-system/capi-kubeadm-bootstrap-controller-manager     capi-kubeadm-control-plane-system/capi-kubeadm-control-plane-controller-manager     caaph-system/caaph-controller-manager argocd/argocd-application-controller; do
    namespace=${target%%/*}
    deployment=${target#*/}
    kubectl logs -n "${namespace}" "deployment/${deployment}" --all-containers --tail=500       >"${evidence_dir}/${namespace}-${deployment}.log" 2>&1 || true
  done
}

verify_openstack_delta() {
  local kind before after delta expected_names expected_lb_ids expected_volume_ids
  for kind in servers networks subnets loadbalancers volumes; do
    before="${evidence_dir}/before-${kind}.json"
    after="${evidence_dir}/after-${kind}.json"
    delta="${evidence_dir}/created-${kind}.json"
    jq --slurpfile before "${before}" '
      [ .[] as $item |
        ($item.ID // $item.Id // $item.id // $item."Volume ID") as $id |
        select(($before[0] | map(.ID // .Id // .id // ."Volume ID") | index($id)) == null) |
        $item ]' "${after}" >"${delta}"
    jq -e --slurpfile after "${after}" '
      all(.[]; (.ID // .Id // .id // ."Volume ID") as $id |
        ($after[0] | map(.ID // .Id // .id // ."Volume ID") | index($id)) != null)' \
      "${before}" >/dev/null || log::die "An unrelated ${kind} object disappeared during the benchmark"
  done

  expected_names=$(printf '%s\n' "${spoke_names[@]}" | jq -R . | jq -s .)
  [[ $(jq 'length' "${evidence_dir}/created-servers.json") == "${expected_servers}" ]] \
    || log::die "Unexpected server delta; inspect created-servers.json"
  jq -e --argjson names "${expected_names}" '
    all(.[]; (.Name // .name // "") as $name |
      any($names[]; . as $prefix | $name | startswith($prefix)))' "${evidence_dir}/created-servers.json" >/dev/null \
    || log::die "An unrelated server was created during the benchmark"
  for kind in networks subnets; do
    [[ $(jq 'length' "${evidence_dir}/created-${kind}.json") == "${expected_networks}" ]] \
      || log::die "Unexpected ${kind} delta"
    jq -e --argjson names "${expected_names}" '
      all(.[]; (.Name // .name // "") as $name |
        any($names[]; . as $spoke | $name == ("csoc-" + $spoke)))' "${evidence_dir}/created-${kind}.json" >/dev/null \
      || log::die "An unrelated ${kind%?} was created during the benchmark"
  done

  expected_lb_ids=$(
    for spoke in "${spoke_names[@]}"; do
      kubectl get openstackcluster "${spoke}" -n "spokeclusters-${spoke}" -o json \
        | jq -r '.status.apiServerLoadBalancer.id'
    done | jq -R . | jq -s 'sort'
  )
  jq -e --argjson expected "${expected_lb_ids}" \
    '[.[] | .ID // .Id // .id] | sort == $expected' \
    "${evidence_dir}/created-loadbalancers.json" >/dev/null \
    || log::die "Unexpected load-balancer delta"

  expected_volume_ids=$(
    jq -r '.[] | .ID // .id' "${evidence_dir}/created-servers.json" |
      while IFS= read -r server_id; do
        openstack server volume list "${server_id}" -f json |
          jq -r '.[] | .ID // .id // ."Volume ID"'
      done | jq -R . | jq -s 'sort'
  )
  jq -e --argjson expected "${expected_volume_ids}" \
    '[.[] | .ID // .Id // .id // ."Volume ID"] | sort == $expected' \
    "${evidence_dir}/created-volumes.json" >/dev/null \
    || log::die "Unexpected root-volume delta"
}

if [[ "${resume}" == true ]]; then
  [[ $(jq -s --arg phase "${phase}" --argjson spokes "${expected_spokes}" \
    '[.[] | select(.event == "benchmark-start" and .phase == $phase and .spokes == $spokes)] | length' \
    "${events_file}") == 1 ]] || log::die "Resume evidence has no unique matching benchmark start"
  [[ $(jq -s '[.[] | select(.event == "benchmark-timeout")] | length' "${events_file}") == 0 ]] \
    || log::die "Timed-out evidence cannot be resumed"
  start_rfc3339=$(jq -sr --arg phase "${phase}" \
    '.[] | select(.event == "benchmark-start" and .phase == $phase) | .time' "${events_file}")
  start_epoch=$(date -u -d "${start_rfc3339}" +%s)
  jq -nc --arg event benchmark-resume --arg phase "${phase}" \
    --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{event:$event,phase:$phase,time:$time}' >>"${events_file}"
  log::step 2 "Resuming ${phase} verification from original T0 ${start_rfc3339}; no sync submitted"
else
  log::step 2 "Recording T0 and enqueueing ${expected_spokes} manual Argo sync operation(s)"
  start_epoch=$(date -u +%s)
  start_rfc3339=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -nc --arg event benchmark-start --arg phase "${phase}" --arg time "${start_rfc3339}"   --argjson spokes "${expected_spokes}"   '{event:$event,phase:$phase,time:$time,spokes:$spokes}' >>"${events_file}"
  argocd --core app sync -l "${selector}" --async   >"${evidence_dir}/argocd-sync.txt"
fi

deadline=$((start_epoch + timeout_seconds))
openstack_all_epoch=0
kubernetes_all_epoch=0
while (( $(date -u +%s) <= deadline )); do
  now_epoch=$(date -u +%s)
  now_rfc3339=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if ! snapshot_openstack; then
    jq -nc --arg event openstack-inventory-error --arg time "${now_rfc3339}"       '{event:$event,time:$time}' >>"${events_file}"
    sleep 15
    continue
  fi

  openstack_count=0
  kubernetes_count=0
  for spoke in "${spoke_names[@]}"; do
    os_ready=false
    k8s_ready=false
    if spoke_openstack_ready "${spoke}"; then
      os_ready=true
      (( openstack_count += 1 ))
      [[ -n "${openstack_ready_at[$spoke]:-}" ]] || openstack_ready_at["${spoke}"]=${now_epoch}
    fi
    if spoke_kubernetes_ready "${spoke}"; then
      k8s_ready=true
      (( kubernetes_count += 1 ))
      [[ -n "${kubernetes_ready_at[$spoke]:-}" ]] || kubernetes_ready_at["${spoke}"]=${now_epoch}
    fi
    jq -nc --arg event observation --arg phase "${phase}" --arg time "${now_rfc3339}"       --arg spoke "${spoke}" --argjson elapsed "$((now_epoch-start_epoch))"       --argjson openstackReady "${os_ready}" --argjson kubernetesReady "${k8s_ready}"       '{event:$event,phase:$phase,time:$time,spoke:$spoke,elapsedSeconds:$elapsed,
        openstackReady:$openstackReady,kubernetesReady:$kubernetesReady}' >>"${events_file}"
  done
  if (( openstack_count == expected_spokes && openstack_all_epoch == 0 )); then
    openstack_all_epoch=${now_epoch}
  fi
  if (( kubernetes_count == expected_spokes && kubernetes_all_epoch == 0 )); then
    kubernetes_all_epoch=${now_epoch}
  fi
  if (( openstack_all_epoch > 0 && kubernetes_all_epoch > 0 )); then
    break
  fi
  sleep 15
done

capture_diagnostics
cp "${evidence_dir}/latest-servers.json" "${evidence_dir}/after-servers.json"
cp "${evidence_dir}/latest-networks.json" "${evidence_dir}/after-networks.json"
cp "${evidence_dir}/latest-subnets.json" "${evidence_dir}/after-subnets.json"
cp "${evidence_dir}/latest-loadbalancers.json" "${evidence_dir}/after-loadbalancers.json"
cp "${evidence_dir}/latest-volumes.json" "${evidence_dir}/after-volumes.json"

if (( openstack_all_epoch == 0 || kubernetes_all_epoch == 0 )); then
  jq -nc --arg event benchmark-timeout --arg phase "${phase}"     --argjson elapsed "$(( $(date -u +%s) - start_epoch ))"     '{event:$event,phase:$phase,elapsedSeconds:$elapsed}' >>"${events_file}"
  log::die "Benchmark timed out; evidence retained at ${evidence_dir}. No cleanup was submitted."
fi

verify_openstack_delta

printf 'spoke,openstack_seconds,kubernetes_seconds,kubernetes_lag_seconds\n' >"${summary_file}"
declare -a os_durations=()
for spoke in "${spoke_names[@]}"; do
  os_seconds=$((openstack_ready_at[$spoke] - start_epoch))
  k8s_seconds=$((kubernetes_ready_at[$spoke] - start_epoch))
  lag=$((kubernetes_ready_at[$spoke] - openstack_ready_at[$spoke]))
  os_durations+=("${os_seconds}")
  printf '%s,%s,%s,%s\n' "${spoke}" "${os_seconds}" "${k8s_seconds}" "${lag}" >>"${summary_file}"
done
mapfile -t sorted_durations < <(printf '%s\n' "${os_durations[@]}" | sort -n)
count=${#sorted_durations[@]}
p50_index=$(( (count * 50 + 99) / 100 - 1 ))
p95_index=$(( (count * 95 + 99) / 100 - 1 ))
openstack_makespan=$((openstack_all_epoch - start_epoch))
kubernetes_makespan=$((kubernetes_all_epoch - start_epoch))
p50=${sorted_durations[$p50_index]}
p95=${sorted_durations[$p95_index]}
throughput=$(awk -v n="${expected_spokes}" -v seconds="${openstack_makespan}"   'BEGIN { if (seconds == 0) print 0; else printf "%.3f", n * 3600 / seconds }')
speedup=null
if [[ "${phase}" == batch ]]; then
  latest_single=$(find "${REPO_ROOT}/.state/benchmarks/v1-scale" -mindepth 2 -maxdepth 2     -path '*-single/metrics.json' -type f -print 2>/dev/null | sort | tail -1)
  if [[ -n "${latest_single}" ]]; then
    single_seconds=$(jq -er '.openstackMakespanSeconds' "${latest_single}")
    speedup=$(awk -v single="${single_seconds}" -v batch="${openstack_makespan}"       'BEGIN { if (batch == 0) print 0; else printf "%.3f", 10 * single / batch }')
  fi
fi
jq -n --arg phase "${phase}" --arg start "${start_rfc3339}"   --argjson spokes "${expected_spokes}"   --argjson openstackMakespanSeconds "${openstack_makespan}"   --argjson kubernetesMakespanSeconds "${kubernetes_makespan}"   --argjson p50OpenstackSeconds "${p50}" --argjson p95OpenstackSeconds "${p95}"   --argjson throughputSpokesPerHour "${throughput}" --argjson speedup "${speedup}"   '{phase:$phase,start:$start,spokes:$spokes,
    openstackMakespanSeconds:$openstackMakespanSeconds,
    kubernetesMakespanSeconds:$kubernetesMakespanSeconds,
    p50OpenstackSeconds:$p50OpenstackSeconds,
    p95OpenstackSeconds:$p95OpenstackSeconds,
    throughputSpokesPerHour:$throughputSpokesPerHour,
    tenTimesSingleOverBatch:$speedup}' >"${metrics_file}"

{
  printf '# Staging v1 scale benchmark: %s\n\n' "${phase}"
  printf -- '- Start: %s\n' "${start_rfc3339}"
  printf -- '- Spokes: %s\n' "${expected_spokes}"
  printf -- '- OpenStack makespan: %s seconds\n' "${openstack_makespan}"
  printf -- '- Kubernetes makespan: %s seconds\n' "${kubernetes_makespan}"
  printf -- '- OpenStack p50/p95: %s/%s seconds\n' "${p50}" "${p95}"
  printf -- '- Throughput: %s spokes/hour\n' "${throughput}"
  [[ "${speedup}" == null ]] || printf -- '- 10 × single / batch: %s\n' "${speedup}"
  printf '\nAll resources remain reconciled; no cleanup was submitted.\n'
} >"${evidence_dir}/README.md"

log::success "Benchmark completed; evidence retained at ${evidence_dir}"
