#!/usr/bin/env bash
# Install CAPI core + CAPO (Cluster API Provider OpenStack) on the management cluster.
# Idempotent: checks for existing installations before acting.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"
source "${REPO_ROOT}/scripts/lib/k8s.sh"

CLUSTERCTL_CONFIG="${REPO_ROOT}/iac/capi/clusterctl-config.yaml"

# Feature gates required by CAPO
export CLUSTER_TOPOLOGY=true
export EXP_CLUSTER_RESOURCE_SET=true
export EXP_MACHINE_POOL=true

log::step 1 "Verifying management cluster connectivity"
kubectl cluster-info >/dev/null \
  || log::die "Cannot reach management cluster. Set KUBECONFIG or run 'make magnum-kubeconfig' first."

# Check whether CAPI is already installed by looking for the CRD.
log::step 2 "Checking existing CAPI installation"
if kubectl get crd clusters.cluster.x-k8s.io >/dev/null 2>&1; then
  log::info "CAPI CRDs already present — upgrading providers if needed."
  CLUSTERCTL_CMD=upgrade
  EXTRA_ARGS=(apply --contract v1beta1)
else
  log::info "CAPI not found — running fresh install."
  CLUSTERCTL_CMD=init
  EXTRA_ARGS=(--infrastructure openstack)
fi

log::step 3 "Running clusterctl ${CLUSTERCTL_CMD}"
clusterctl "${CLUSTERCTL_CMD}" \
  --config "${CLUSTERCTL_CONFIG}" \
  "${EXTRA_ARGS[@]}"

log::step 4 "Waiting for CAPI controllers to be ready"
kubectl wait deployment \
  --all \
  --namespace capi-system \
  --for=condition=Available \
  --timeout=300s

kubectl wait deployment \
  --all \
  --namespace capo-system \
  --for=condition=Available \
  --timeout=300s

log::success "CAPI + CAPO controllers are running."
log::info "Next: run 'make capi-secret' then 'make capi-cluster'"
