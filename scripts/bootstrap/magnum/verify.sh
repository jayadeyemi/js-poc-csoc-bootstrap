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

log::step 1 "Confirming CSOC API reachability with the exact cluster kubeconfig"
[[ -n "${API_ADDRESS}" ]] || log::die "Magnum did not report the CSOC API address"
bash "${REPO_ROOT}/scripts/lib/kubernetes-reachability.sh" \
  --name "${MAGNUM_CLUSTER_NAME}" \
  --kubeconfig "${KUBECONFIG_FILE}" \
  --minimum-ready "${MAGNUM_EXPECTED_INITIAL_NODES}" \
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

log::step 3 "Checking 100-GiB roots and default worker autoscaling bounds"
STACK_ID=$(jq -r '.stack_id' <<<"${CLUSTER_JSON}")
mapfile -t SERVER_IDS < <(openstack server list -f json \
  | jq -r --arg stack "${STACK_ID}" '.[] | select((.Name // .name // "") | contains($stack)) | (.ID // .id)')
(( ${#SERVER_IDS[@]} == MAGNUM_EXPECTED_INITIAL_NODES )) \
  || log::die "Expected ${MAGNUM_EXPECTED_INITIAL_NODES} Magnum servers, found ${#SERVER_IDS[@]}"
for server_id in "${SERVER_IDS[@]}"; do
  SERVER_JSON=$(openstack server show "${server_id}" -f json)
  volume_id=$(jq -r '.volumes_attached[0].id // ."volumes_attached"[0].id // empty' <<<"${SERVER_JSON}")
  [[ -n "${volume_id}" ]] || log::die "Server ${server_id} has no attached boot volume"
  VOLUME_JSON=$(openstack volume show "${volume_id}" -f json)
  [[ $(jq -r '.size' <<<"${VOLUME_JSON}") == "${MAGNUM_BOOT_VOLUME_SIZE}" ]] \
    || log::die "Server ${server_id} boot volume is not ${MAGNUM_BOOT_VOLUME_SIZE} GiB"
done
NODEGROUP_JSON=$(openstack coe nodegroup show "${CLUSTER_ID}" default-worker -f json)
[[ $(jq -r '.min_node_count' <<<"${NODEGROUP_JSON}") == "${MAGNUM_MIN_NODE_COUNT}" \
   && $(jq -r '.max_node_count' <<<"${NODEGROUP_JSON}") == "${MAGNUM_MAX_NODE_COUNT}" ]] \
  || log::die "Default worker autoscaling bounds do not match ${MAGNUM_MIN_NODE_COUNT}..${MAGNUM_MAX_NODE_COUNT}"
log::success "Management cluster satisfies the guide-exact readiness contract"
