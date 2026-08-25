#!/usr/bin/env bash
# Deliberately remove one Git-retired spoke through workload, CAPI, then KRO/ORC ownership.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
FLEET_ROOT="${FLEET_ROOT:-${WORKSPACE_ROOT}/js-poc-csoc-fleet}"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/credentials.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
csoc::load_profile "${REPO_ROOT}"
[[ "${CSOC_FLEET_ENABLED}" == true ]] \
  || log::die "Profile ${CSOC_PROFILE} has no fleet lifecycle"
export KUBECONFIG="${KUBECONFIG:-${MAGNUM_KUBECONFIG_DIR}/config}"

usage() {
  printf 'Usage: %s --identity IDENTITY --spoke SPOKE --confirm SPOKE [--delete-identity]\n' "$0" >&2
  exit 64
}

IDENTITY=
SPOKE=
CONFIRM=
DELETE_IDENTITY=false
while (( $# > 0 )); do
  case "$1" in
    --identity) (( $# >= 2 )) || usage; IDENTITY=$2; shift 2 ;;
    --spoke) (( $# >= 2 )) || usage; SPOKE=$2; shift 2 ;;
    --confirm) (( $# >= 2 )) || usage; CONFIRM=$2; shift 2 ;;
    --delete-identity) DELETE_IDENTITY=true; shift ;;
    *) usage ;;
  esac
done

for value in "${IDENTITY}" "${SPOKE}"; do
  [[ "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || log::die "Identity and spoke names must be DNS labels"
done
[[ "${CONFIRM}" == "${SPOKE}" ]] \
  || log::die "Refusing deletion: --confirm must exactly equal '${SPOKE}'"

for command_name in git jq kubectl openstack tar yq; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || log::die "Required command not found: ${command_name}"
done
[[ -d "${FLEET_ROOT}/.git" ]] || log::die "Fleet repository not found: ${FLEET_ROOT}"

NAMESPACE="spokeclusters-${IDENTITY}"
EVIDENCE_ROOT="${SPOKE_DESTROY_EVIDENCE_ROOT:-${REPO_ROOT}/.state/spoke-destroy}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-${IDENTITY}-${SPOKE}"
EVIDENCE_DIR="${EVIDENCE_ROOT}/${RUN_ID}"
mkdir -p "${EVIDENCE_DIR}"
chmod 700 "${EVIDENCE_ROOT}" "${EVIDENCE_DIR}"

wait_absent() {
  local description=$1 timeout=$2
  shift 2
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if ! "$@" >/dev/null 2>&1; then
      log::success "Absent: ${description}"
      return 0
    fi
    sleep 10
  done
  log::die "Timed out waiting for ${description} to disappear; no force-delete was attempted"
}

wait_openstack_absent() {
  local resource=$1 resource_id=$2 timeout=${3:-1800}
  [[ -n "${resource_id}" && "${resource_id}" != null ]] || return 0
  wait_absent "OpenStack ${resource} ${resource_id}" "${timeout}" \
    openstack "${resource}" show "${resource_id}"
}

log::step 1 "Proving Git and Argo no longer declare '${SPOKE}'"
git -C "${FLEET_ROOT}" fetch --quiet origin main
DESIRED_TREE="$(mktemp -d)"
cleanup() {
  rm -rf -- "${DESIRED_TREE}"
  [[ -z "${WORKLOAD_KUBECONFIG:-}" ]] || rm -f -- "${WORKLOAD_KUBECONFIG}"
}
trap cleanup EXIT
git -C "${FLEET_ROOT}" archive origin/main | tar -x -C "${DESIRED_TREE}"
kubectl kustomize "${DESIRED_TREE}" >"${EVIDENCE_DIR}/fleet-default-branch.yaml"
if SPOKE_NAME="${SPOKE}" SPOKE_NAMESPACE="${NAMESPACE}" yq -e \
    'select(.metadata.name == strenv(SPOKE_NAME) and .metadata.namespace == strenv(SPOKE_NAMESPACE))' \
    "${EVIDENCE_DIR}/fleet-default-branch.yaml" >/dev/null; then
  log::die "Fleet origin/main still declares ${NAMESPACE}/${SPOKE}; merge its removal first"
fi
[[ "$(kubectl get application csoc-fleet -n argocd -o jsonpath='{.status.sync.status}')" == Synced ]] \
  || log::die "Argo Application csoc-fleet must be Synced before deletion"
[[ "$(kubectl get application csoc-fleet -n argocd -o jsonpath='{.spec.syncPolicy.automated.prune}')" == false ]] \
  || log::die "csoc-fleet must retain prune=false for deliberate deletion"

log::step 2 "Capturing Kubernetes, CAPI, KRO, and exact OpenStack ownership"
kubectl get namespace "${NAMESPACE}" -o json >"${EVIDENCE_DIR}/namespace.json"
PROJECT_ID=$(jq -r '.metadata.labels["csoc.js2.org/openstack-project-id"] // ""' \
  "${EVIDENCE_DIR}/namespace.json")
[[ "${PROJECT_ID}" =~ ^[0-9a-fA-F]{32}$ ]] \
  || log::die "Namespace ${NAMESPACE} lacks a trusted OpenStack project ID"

RUNTIME_FILE=$(credentials::runtime_file "${IDENTITY}")
credentials::require_private_file "${RUNTIME_FILE}" "${IDENTITY} runtime"
export OS_CLIENT_CONFIG_FILE="${RUNTIME_FILE}"
export OS_CLOUD=openstack
CREDENTIAL_METADATA=$(credentials::metadata "${RUNTIME_FILE}" openstack)
credentials::require_unexpired "${CREDENTIAL_METADATA}" "${IDENTITY} runtime"
[[ "$(jq -r '.project_id' <<<"${CREDENTIAL_METADATA}")" == "${PROJECT_ID}" \
   && "$(jq -r '.app_project_id' <<<"${CREDENTIAL_METADATA}")" == "${PROJECT_ID}" \
   && "$(jq -r '.unrestricted' <<<"${CREDENTIAL_METADATA}")" == false ]] \
  || log::die "Restricted runtime credential does not match ${NAMESPACE}'s trusted project"

kubectl get spokecluster "${SPOKE}" -n "${NAMESPACE}" -o json \
  >"${EVIDENCE_DIR}/spokecluster.json"
kubectl get cluster "${SPOKE}" -n "${NAMESPACE}" -o json \
  >"${EVIDENCE_DIR}/capi-cluster.json"
kubectl get openstackcluster "${SPOKE}" -n "${NAMESPACE}" -o json \
  >"${EVIDENCE_DIR}/openstackcluster.json"
kubectl get machines -n "${NAMESPACE}" -l "cluster.x-k8s.io/cluster-name=${SPOKE}" -o json \
  >"${EVIDENCE_DIR}/machines.json"

NETWORK_KIND=
for kind in dedicatedspokenetwork routedspokenetwork fullymanagedspokenetwork \
  isolatedopenstacknetwork importedspokenetwork sharedprovidernetwork autoallocatedspokenetwork; do
  if kubectl get "${kind}" "${SPOKE}" -n "${NAMESPACE}" -o json \
      >"${EVIDENCE_DIR}/network-graph.json" 2>/dev/null; then
    NETWORK_KIND=${kind}
    break
  fi
done
[[ -n "${NETWORK_KIND}" ]] || log::die "No supported network graph owns ${NAMESPACE}/${SPOKE}"

NETWORK_ID=$(jq -r '.status.networkID // ""' "${EVIDENCE_DIR}/network-graph.json")
SUBNET_ID=$(jq -r '.status.subnetID // ""' "${EVIDENCE_DIR}/network-graph.json")
ROUTER_ID=$(jq -r '.status.routerID // ""' "${EVIDENCE_DIR}/network-graph.json")
API_LB_ID=$(jq -r '.status.loadBalancerID // ""' "${EVIDENCE_DIR}/spokecluster.json")
jq -n --arg identity "${IDENTITY}" --arg spoke "${SPOKE}" --arg namespace "${NAMESPACE}" \
  --arg networkKind "${NETWORK_KIND}" --arg networkID "${NETWORK_ID}" \
  --arg subnetID "${SUBNET_ID}" --arg routerID "${ROUTER_ID}" --arg apiLoadBalancerID "${API_LB_ID}" \
  '{identity:$identity,spoke:$spoke,namespace:$namespace,networkKind:$networkKind,networkID:$networkID,subnetID:$subnetID,routerID:$routerID,apiLoadBalancerID:$apiLoadBalancerID}' \
  >"${EVIDENCE_DIR}/ownership.json"

WORKLOAD_KUBECONFIG="$(mktemp)"
chmod 600 "${WORKLOAD_KUBECONFIG}"
kubectl get secret "${SPOKE}-kubeconfig" -n "${NAMESPACE}" -o jsonpath='{.data.value}' \
  | base64 -d >"${WORKLOAD_KUBECONFIG}"
kubectl --kubeconfig "${WORKLOAD_KUBECONFIG}" get namespace hello-app -o json \
  >"${EVIDENCE_DIR}/hello-app-namespace.json" 2>/dev/null || true

log::step 3 "Deleting the spoke workload before its CAPI cluster"
kubectl --kubeconfig "${WORKLOAD_KUBECONFIG}" delete namespace hello-app \
  --ignore-not-found --wait=true --timeout=15m
kubectl delete helloapp "${SPOKE}" -n "${NAMESPACE}" --ignore-not-found --wait=true --timeout=15m

log::step 4 "Deleting SpokeCluster and waiting for CAPI/CAPO ownership cleanup"
kubectl delete spokecluster "${SPOKE}" -n "${NAMESPACE}" --wait=false
wait_absent "SpokeCluster ${NAMESPACE}/${SPOKE}" 3600 \
  kubectl get spokecluster "${SPOKE}" -n "${NAMESPACE}"
wait_absent "CAPI Cluster ${NAMESPACE}/${SPOKE}" 3600 \
  kubectl get cluster "${SPOKE}" -n "${NAMESPACE}"
wait_openstack_absent loadbalancer "${API_LB_ID}" 3600
while IFS= read -r server_id; do
  wait_openstack_absent server "${server_id}" 3600
done < <(jq -r '.items[].status.instanceID // empty | sub("^openstack:///"; "")' \
  "${EVIDENCE_DIR}/machines.json")

log::step 5 "Deleting the network graph after every CAPI resource is gone"
case "${NETWORK_KIND}" in
  autoallocatedspokenetwork|importedspokenetwork|sharedprovidernetwork)
    log::warn "${NETWORK_KIND} imports provider/external topology; its OpenStack objects will be preserved"
    ;;
  dedicatedspokenetwork|routedspokenetwork|fullymanagedspokenetwork|isolatedopenstacknetwork) ;;
  *) log::die "Unsupported network ownership kind: ${NETWORK_KIND}" ;;
esac
kubectl delete "${NETWORK_KIND}" "${SPOKE}" -n "${NAMESPACE}" --wait=false
wait_absent "${NETWORK_KIND} ${NAMESPACE}/${SPOKE}" 1800 \
  kubectl get "${NETWORK_KIND}" "${SPOKE}" -n "${NAMESPACE}"
if [[ "${NETWORK_KIND}" == dedicatedspokenetwork || "${NETWORK_KIND}" == routedspokenetwork \
   || "${NETWORK_KIND}" == fullymanagedspokenetwork \
   || "${NETWORK_KIND}" == isolatedopenstacknetwork ]]; then
  wait_openstack_absent subnet "${SUBNET_ID}"
  wait_openstack_absent network "${NETWORK_ID}"
fi
if [[ "${NETWORK_KIND}" == routedspokenetwork || "${NETWORK_KIND}" == fullymanagedspokenetwork ]]; then
  wait_openstack_absent router "${ROUTER_ID}"
elif [[ -n "${ROUTER_ID}" ]]; then
  openstack router show "${ROUTER_ID}" -f json >"${EVIDENCE_DIR}/preserved-router.json" \
    || log::die "Shared/imported router ${ROUTER_ID} was unexpectedly removed"
fi

log::step 6 "Deleting write-once spoke blocks after infrastructure cleanup"
kubectl delete spokeenvironmentconfig "${SPOKE}" -n "${NAMESPACE}" \
  --ignore-not-found --wait=true --timeout=10m
kubectl delete spokenetworkimportconfig "${SPOKE}" -n "${NAMESPACE}" \
  --ignore-not-found --wait=true --timeout=10m
kubectl delete spokesharednetworkconfig "${SPOKE}" -n "${NAMESPACE}" \
  --ignore-not-found --wait=true --timeout=10m
if [[ "${DELETE_IDENTITY}" == true ]]; then
  # Different RGDs have different lifecycle and data-loss semantics. Never let
  # identity namespace deletion implicitly erase an optional or future graph.
  # The operator must retire those instances explicitly, then rerun this
  # idempotent operation.
  declare -a remaining_graphs=()
  while IFS= read -r resource_type; do
    while IFS= read -r resource_name; do
      [[ -z "${resource_name}" ]] || remaining_graphs+=("${resource_name}")
    done < <(kubectl get "${resource_type}" -n "${NAMESPACE}" -o name 2>/dev/null || true)
  done < <(kubectl api-resources --api-group=csoc.js2.org --namespaced=true -o name | sort)
  (( ${#remaining_graphs[@]} == 0 )) \
    || log::die "Account namespace still contains independently owned graphs: ${remaining_graphs[*]}. Review and delete each graph explicitly before deleting the identity."
  kubectl delete spokeidentity "${IDENTITY}" --ignore-not-found --wait=true --timeout=15m
  kubectl delete immutablespokeconfig "${IDENTITY}" --ignore-not-found --wait=true --timeout=15m
else
  log::info "SpokeIdentity/${IDENTITY} and its account credential boundary were preserved"
fi

log::success "Spoke ${SPOKE} was removed in workload → CAPI → network order. Evidence: ${EVIDENCE_DIR}"
