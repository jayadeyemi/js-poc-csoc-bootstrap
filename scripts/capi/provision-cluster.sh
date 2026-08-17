#!/usr/bin/env bash
# Provision a CAPI workload cluster from a cluster directory.
# Usage: provision-cluster.sh <cluster-dir>
# Example: provision-cluster.sh iac/capi/clusters/example-cluster
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"
source "${REPO_ROOT}/scripts/lib/k8s.sh"

CLUSTER_DIR="${1:?Usage: $0 <cluster-dir>}"
[[ "${CLUSTER_DIR}" = /* ]] || CLUSTER_DIR="${REPO_ROOT}/${CLUSTER_DIR}"

VALUES_ENV="${CLUSTER_DIR}/values.env"
[[ -f "${VALUES_ENV}" ]] || log::die "values.env not found at: ${VALUES_ENV}"

# Load cluster-specific values, then export so envsubst can see them.
set -o allexport
# shellcheck source=iac/capi/clusters/example-cluster/values.env
source "${VALUES_ENV}"
set +o allexport

TEMPLATE="${REPO_ROOT}/iac/capi/templates/openstack-cluster.yaml"
[[ -f "${TEMPLATE}" ]] || log::die "Cluster template not found: ${TEMPLATE}"

log::step 1 "Provisioning cluster '${CLUSTER_NAME}' (namespace: ${CAPI_NAMESPACE})"

# Validate required variables are set
: "${CLUSTER_NAME:?CLUSTER_NAME must be set in values.env}"
: "${SSH_KEY_NAME:?SSH_KEY_NAME must be set in values.env}"
: "${NODE_IMAGE_NAME:?NODE_IMAGE_NAME must be set in values.env}"

log::step 2 "Ensuring cloud secret is present"
bash "${SCRIPT_DIR}/create-cloud-secret.sh"

log::step 3 "Applying cluster manifests (server-side apply)"
envsubst < "${TEMPLATE}" | kubectl apply --server-side -f -

log::step 4 "Waiting for cluster '${CLUSTER_NAME}' to become ready"
k8s::wait_capi_cluster "${CLUSTER_NAME}" "${CAPI_NAMESPACE}" "${CAPI_TIMEOUT:-900}"

log::step 5 "Retrieving workload cluster kubeconfig"
WORKLOAD_KUBECONFIG="${HOME}/.kube/${CLUSTER_NAME}.yaml"
clusterctl get kubeconfig "${CLUSTER_NAME}" \
  --namespace "${CAPI_NAMESPACE}" \
  > "${WORKLOAD_KUBECONFIG}"
chmod 600 "${WORKLOAD_KUBECONFIG}"

k8s::merge_kubeconfig "${WORKLOAD_KUBECONFIG}"

log::success "Cluster '${CLUSTER_NAME}' is ready."
log::info   "Test: kubectl --kubeconfig=${WORKLOAD_KUBECONFIG} get nodes"
