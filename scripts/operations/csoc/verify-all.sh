#!/usr/bin/env bash
# Live validation for one selected CSOC and every SpokeCluster it manages.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
csoc::load_profile "${REPO_ROOT}"
export KUBECONFIG="${KUBECONFIG:-${MAGNUM_KUBECONFIG_DIR}/config}"

log::step 1 "Validate all declarative management and spoke clusters"
bash "${REPO_ROOT}/scripts/tools/validate-clusters.sh"
log::step 2 "Validate the ${CSOC_PROFILE} Magnum management cluster"
MAGNUM_VERIFY_NODE_MODE=bounds bash "${REPO_ROOT}/scripts/bootstrap/magnum/verify.sh"

log::step 3 "Validate every active SpokeCluster through KRO and CAPI status"
if ! kubectl api-resources -o name | rg -Fx 'spokeclusters.csoc.js2.org' >/dev/null; then
  log::info "SpokeCluster API is not installed; no active spokes can exist"
  exit 0
fi

spokes_json=$(kubectl get spokeclusters.csoc.js2.org --all-namespaces -o json)
spoke_count=$(jq '.items | length' <<<"${spokes_json}")
if (( spoke_count == 0 )); then
  log::success "Management cluster is ready and has no active spokes"
  exit 0
fi

while IFS=$'\t' read -r namespace name min_nodes max_nodes ready addons_ready autoscaler_ready; do
  [[ "${min_nodes}" =~ ^[0-9]+$ && "${max_nodes}" =~ ^[0-9]+$ ]] \
    || log::die "${namespace}/${name} has invalid worker bounds"
  (( min_nodes >= 1 && min_nodes <= max_nodes )) \
    || log::die "${namespace}/${name} violates 1 <= minNodes <= maxNodes"
  [[ "${ready}" == true && "${addons_ready}" == true && "${autoscaler_ready}" == true ]] \
    || log::die "${namespace}/${name} is not fully ready (cluster=${ready}, addons=${addons_ready}, autoscaler=${autoscaler_ready})"

  capi_json=$(kubectl get clusters.cluster.x-k8s.io "${name}" -n "${namespace}" -o json)
  jq -e '
    ((.status.infrastructureReady // false) or
      any(.status.conditions[]?; .type == "InfrastructureReady" and .status == "True")) and
    ((.status.controlPlaneReady // false) or
      any(.status.conditions[]?;
        (.type == "ControlPlaneReady" or .type == "ControlPlaneAvailable") and .status == "True")) and
    (any(.status.conditions[]?;
       (.type == "Ready" or .type == "Available") and .status == "True"))
  ' <<<"${capi_json}" >/dev/null \
    || log::die "CAPI Cluster ${namespace}/${name} is not Ready"

  deployments_json=$(kubectl get machinedeployments.cluster.x-k8s.io -n "${namespace}" \
    -l "cluster.x-k8s.io/cluster-name=${name}" -o json)
  deployment_count=$(jq '.items | length' <<<"${deployments_json}")
  (( deployment_count > 0 )) \
    || log::die "${namespace}/${name} has no worker MachineDeployment"
  jq -e --argjson min "${min_nodes}" --argjson max "${max_nodes}" '
    all(.items[];
      ((.status.replicas // 0) >= $min) and
      ((.status.replicas // 0) <= $max) and
      ((.status.readyReplicas // 0) == (.status.replicas // 0)) and
      ((.status.availableReplicas // 0) == (.status.replicas // 0)))
  ' <<<"${deployments_json}" >/dev/null \
    || log::die "${namespace}/${name} workers are unready or outside declared bounds"
  log::success "${namespace}/${name}: ready with worker count inside ${min_nodes}..${max_nodes}"
done < <(
  jq -r '.items[] |
    [.metadata.namespace, .metadata.name,
     .spec.kubernetes.minNodes, .spec.kubernetes.maxNodes,
     (.status.ready // false), (.status.addonsReady // false),
     (.status.autoscalerReady // false)] | @tsv' <<<"${spokes_json}"
)

log::success "Validated ${CSOC_PROFILE} and all ${spoke_count} active spoke cluster(s)"
