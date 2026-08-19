#!/usr/bin/env bash
# Exercise the Magnum default worker group within its declared 1..2 bounds.
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
NAMESPACE="magnum-autoscaling-smoke-$(date -u +%s)"
AUTOSCALE_UP_TIMEOUT="${MAGNUM_AUTOSCALE_UP_TIMEOUT:-1200}"
AUTOSCALE_DOWN_TIMEOUT="${MAGNUM_AUTOSCALE_DOWN_TIMEOUT:-1800}"

cleanup() {
  kubectl delete namespace "${NAMESPACE}" --wait --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl create namespace "${NAMESPACE}" >/dev/null
kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: scale-pressure
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: scale-pressure
  template:
    metadata:
      labels:
        app: scale-pressure
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          resources:
            requests:
              cpu: 2500m
              memory: 512Mi
EOF

log::step 1 "Waiting for default workers to scale ${MAGNUM_MIN_NODE_COUNT} → ${MAGNUM_MAX_NODE_COUNT}"
deadline=$((SECONDS + AUTOSCALE_UP_TIMEOUT))
while (( SECONDS < deadline )); do
  NODEGROUP_JSON=$(openstack coe nodegroup show "${CLUSTER_ID}" default-worker -f json)
  worker_count=$(jq -r '.node_count' <<<"${NODEGROUP_JSON}")
  NODES_JSON=$(kubectl get nodes -o json)
  ready_count=$(jq '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length' <<<"${NODES_JSON}")
  (( worker_count <= MAGNUM_MAX_NODE_COUNT )) \
    || log::die "Autoscaler exceeded maximum worker bound"
  if (( worker_count == MAGNUM_MAX_NODE_COUNT && ready_count == MAGNUM_MASTER_COUNT + MAGNUM_MAX_NODE_COUNT )); then
    break
  fi
  sleep 15
done
(( worker_count == MAGNUM_MAX_NODE_COUNT )) || log::die "Workers did not scale up to ${MAGNUM_MAX_NODE_COUNT}"

log::step 2 "Removing pressure and waiting for workers to return to ${MAGNUM_MIN_NODE_COUNT}"
kubectl -n "${NAMESPACE}" scale deployment/scale-pressure --replicas=0 >/dev/null
deadline=$((SECONDS + AUTOSCALE_DOWN_TIMEOUT))
while (( SECONDS < deadline )); do
  NODEGROUP_JSON=$(openstack coe nodegroup show "${CLUSTER_ID}" default-worker -f json)
  worker_count=$(jq -r '.node_count' <<<"${NODEGROUP_JSON}")
  (( worker_count >= MAGNUM_MIN_NODE_COUNT )) \
    || log::die "Autoscaler dropped below minimum worker bound"
  (( worker_count == MAGNUM_MIN_NODE_COUNT )) && break
  sleep 30
done
(( worker_count == MAGNUM_MIN_NODE_COUNT )) || log::die "Workers did not scale down to ${MAGNUM_MIN_NODE_COUNT}"
cleanup
trap - EXIT
log::success "Management worker autoscaling remained within ${MAGNUM_MIN_NODE_COUNT}..${MAGNUM_MAX_NODE_COUNT}"
