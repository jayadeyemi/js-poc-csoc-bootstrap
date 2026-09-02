#!/usr/bin/env bash
# Verify the guide-exact management cluster before installing Argo CD.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/openstack.bash"
source "${REPO_ROOT}/scripts/lib/credentials.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
csoc::load_profile "${REPO_ROOT}"

STATE_FILE="${MAGNUM_STATE_FILE:-${REPO_ROOT}/.state/magnum-cluster.json}"
KUBECONFIG_FILE="${MAGNUM_KUBECONFIG_FILE:-${MAGNUM_KUBECONFIG_DIR:-${HOME}/.kube}/${MAGNUM_CLUSTER_NAME}.yaml}"
credentials::configure_magnum
CLUSTER_ID=$(os::verify_owned_cluster "${STATE_FILE}" "${MAGNUM_CLUSTER_NAME}")
CLUSTER_JSON=$(openstack coe cluster show "${CLUSTER_ID}" -f json)
API_ADDRESS=$(jq -r '.api_address // empty' <<<"${CLUSTER_JSON}")
VERIFY_NODE_MODE=${MAGNUM_VERIFY_NODE_MODE:-exact}
case "${VERIFY_NODE_MODE}" in
  exact) MINIMUM_READY_NODES=${MAGNUM_EXPECTED_INITIAL_NODES} ;;
  bounds) MINIMUM_READY_NODES=$((MAGNUM_MASTER_COUNT + MAGNUM_MIN_NODE_COUNT)) ;;
  *) log::die "MAGNUM_VERIFY_NODE_MODE must be exact or bounds" ;;
esac

log::step 1 "Confirming CSOC API reachability with the exact cluster kubeconfig"
[[ -n "${API_ADDRESS}" ]] || log::die "Magnum did not report the CSOC API address"
bash "${REPO_ROOT}/scripts/lib/kubernetes-reachability.sh" \
  --name "${MAGNUM_CLUSTER_NAME}" \
  --kubeconfig "${KUBECONFIG_FILE}" \
  --minimum-ready "${MINIMUM_READY_NODES}" \
  --expected-endpoint "${API_ADDRESS}" \
  --timeout "${MAGNUM_VERIFY_TIMEOUT}s"

log::step 2 "Checking Calico, CoreDNS, and DNS resolution"
kubectl -n calico-system rollout status daemonset/calico-node --timeout=5m
kubectl -n kube-system rollout status deployment/coredns --timeout=5m
DNS_NAMESPACE="magnum-dns-smoke-$(date -u +%s)"
cleanup_dns() {
  kubectl delete namespace "${DNS_NAMESPACE}" --wait --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup_dns EXIT
kubectl create namespace "${DNS_NAMESPACE}" >/dev/null
kubectl -n "${DNS_NAMESPACE}" run dns-smoke \
  --image=mirror.gcr.io/library/busybox:1.36 \
  --restart=Never --command -- nslookup kubernetes.default.svc.cluster.local >/dev/null
kubectl -n "${DNS_NAMESPACE}" wait \
  --for=jsonpath='{.status.phase}'=Succeeded pod/dns-smoke --timeout=2m >/dev/null
kubectl -n "${DNS_NAMESPACE}" logs dns-smoke \
  | grep -F 'kubernetes.default.svc.cluster.local' >/dev/null
cleanup_dns
trap - EXIT

log::step 3 "Checking ${MAGNUM_BOOT_VOLUME_SIZE}-GiB roots and default worker bounds"
STACK_ID=$(jq -r '.stack_id' <<<"${CLUSTER_JSON}")
mapfile -t SERVER_IDS < <(openstack server list -f json \
  | jq -r --arg stack "${STACK_ID}" '.[] | select((.Name // .name // "") | contains($stack)) | (.ID // .id)')
if [[ "${VERIFY_NODE_MODE}" == exact ]]; then
  (( ${#SERVER_IDS[@]} == MAGNUM_EXPECTED_INITIAL_NODES )) \
    || log::die "Expected ${MAGNUM_EXPECTED_INITIAL_NODES} Magnum servers, found ${#SERVER_IDS[@]}"
else
  minimum_servers=$((MAGNUM_MASTER_COUNT + MAGNUM_MIN_NODE_COUNT))
  maximum_servers=$((MAGNUM_MASTER_COUNT + MAGNUM_MAX_NODE_COUNT))
  (( ${#SERVER_IDS[@]} >= minimum_servers && ${#SERVER_IDS[@]} <= maximum_servers )) \
    || log::die "Magnum server count ${#SERVER_IDS[@]} is outside ${minimum_servers}..${maximum_servers}"
fi
for server_id in "${SERVER_IDS[@]}"; do
  SERVER_JSON=$(openstack server show "${server_id}" -f json)
  mapfile -t attached_volume_ids < <(jq -r '(.volumes_attached // [])[]? | .id // empty' <<<"${SERVER_JSON}")
  (( ${#attached_volume_ids[@]} == 1 )) \
    || log::die "Server ${server_id} must have exactly one boot volume attachment"
  volume_id=${attached_volume_ids[0]}
  VOLUME_JSON=$(openstack volume show "${volume_id}" -f json)
  [[ $(jq -r '.id // empty' <<<"${VOLUME_JSON}") == "${volume_id}" ]] \
    || log::die "Server ${server_id} volume lookup did not return the attached UUID"
  [[ $(jq -r '.size' <<<"${VOLUME_JSON}") == "${MAGNUM_BOOT_VOLUME_SIZE}" ]] \
    || log::die "Server ${server_id} boot volume is not ${MAGNUM_BOOT_VOLUME_SIZE} GiB"
  [[ $(jq -r '(.status // "") | ascii_downcase' <<<"${VOLUME_JSON}") == in-use ]] \
    || log::die "Server ${server_id} boot volume is not in-use"
  [[ $(jq -r '(.bootable // false) | tostring | ascii_downcase' <<<"${VOLUME_JSON}") == true ]] \
    || log::die "Server ${server_id} root attachment is not marked bootable"
  [[ $(jq -r '(.multiattach // false) | tostring | ascii_downcase' <<<"${VOLUME_JSON}") == false ]] \
    || log::die "Server ${server_id} boot volume must not permit multi-attach"
  [[ $(jq -r --arg server "${server_id}" \
       '(.attachments // []) | length == 1 and ((.[0].server_id // .[0].serverId // "") == $server)' \
       <<<"${VOLUME_JSON}") == true ]] \
    || log::die "Boot volume ${volume_id} is not attached only to expected server ${server_id}"
  volume_project=$(jq -r '."os-vol-tenant-attr:tenant_id" // .project_id // empty' <<<"${VOLUME_JSON}")
  [[ -z "${volume_project}" || "${volume_project}" == "${MAGNUM_PROJECT_ID}" ]] \
    || log::die "Server ${server_id} boot volume belongs to a different OpenStack project"
done
NODEGROUP_JSON=$(openstack coe nodegroup show "${CLUSTER_ID}" default-worker -f json)
[[ $(jq -r '.min_node_count' <<<"${NODEGROUP_JSON}") == "${MAGNUM_MIN_NODE_COUNT}" \
   && $(jq -r '.max_node_count' <<<"${NODEGROUP_JSON}") == "${MAGNUM_MAX_NODE_COUNT}" ]] \
  || log::die "Default worker autoscaling bounds do not match ${MAGNUM_MIN_NODE_COUNT}..${MAGNUM_MAX_NODE_COUNT}"
log::success "Management cluster satisfies the guide-exact readiness contract"
