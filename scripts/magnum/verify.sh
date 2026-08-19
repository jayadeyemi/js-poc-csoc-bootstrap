#!/usr/bin/env bash
# Verify the guide-exact management cluster before installing Argo CD.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"
source "${REPO_ROOT}/scripts/lib/openstack.sh"
source "${REPO_ROOT}/scripts/lib/credentials.sh"
source "${REPO_ROOT}/iac/magnum/cluster.env"

STATE_FILE="${MAGNUM_STATE_FILE:-${REPO_ROOT}/.state/magnum-cluster.json}"
credentials::configure_magnum
CLUSTER_ID=$(os::verify_owned_cluster "${STATE_FILE}" "${MAGNUM_CLUSTER_NAME}")

log::step 1 "Checking Kubernetes API and exactly ${MAGNUM_EXPECTED_INITIAL_NODES} Ready nodes"
kubectl get --raw=/readyz >/dev/null
deadline=$((SECONDS + MAGNUM_VERIFY_TIMEOUT))
while (( SECONDS < deadline )); do
  NODES_JSON=$(kubectl get nodes -o json)
  node_count=$(jq '.items | length' <<<"${NODES_JSON}")
  ready_count=$(jq '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length' <<<"${NODES_JSON}")
  log::info "nodes=${node_count} ready=${ready_count}"
  if (( node_count == MAGNUM_EXPECTED_INITIAL_NODES && ready_count == MAGNUM_EXPECTED_INITIAL_NODES )); then
    break
  fi
  sleep 15
done
(( node_count == MAGNUM_EXPECTED_INITIAL_NODES && ready_count == MAGNUM_EXPECTED_INITIAL_NODES )) \
  || log::die "Initial node readiness did not converge"
jq -e '[.items[].spec.taints[]? | select(.key == "node.cloudprovider.kubernetes.io/uninitialized")] | length == 0' \
  <<<"${NODES_JSON}" >/dev/null \
  || log::die "OpenStack cloud-provider initialization taint remains"

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
CLUSTER_JSON=$(openstack coe cluster show "${CLUSTER_ID}" -f json)
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
