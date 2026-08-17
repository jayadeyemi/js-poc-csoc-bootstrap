#!/usr/bin/env bash
# Retrieve the kubeconfig for the Magnum cluster and merge it into ~/.kube/config.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"
source "${REPO_ROOT}/scripts/lib/openstack.sh"
source "${REPO_ROOT}/scripts/lib/k8s.sh"

source "${REPO_ROOT}/iac/magnum/cluster.env"

KUBECONFIG_DIR="${HOME}/.kube"
KUBECONFIG_FILE="${KUBECONFIG_DIR}/${MAGNUM_CLUSTER_NAME}.yaml"

log::step 1 "Verifying cluster is active"
status=$(os::cluster_status "${MAGNUM_CLUSTER_NAME}")
[[ "${status}" == "CREATE_COMPLETE" ]] \
  || log::die "Cluster is not active (status: ${status}). Run 'make magnum-wait' first."

mkdir -p "${KUBECONFIG_DIR}"

log::step 2 "Fetching kubeconfig → ${KUBECONFIG_FILE}"
openstack coe cluster config "${MAGNUM_CLUSTER_NAME}" \
  --use-keyring \
  --output-certs \
  --force \
  --dir "${KUBECONFIG_DIR}" 2>/dev/null \
  || openstack coe cluster config "${MAGNUM_CLUSTER_NAME}" \
       --force \
       --dir "${KUBECONFIG_DIR}"

# Magnum writes the file as "config" in the target dir; rename for clarity.
if [[ -f "${KUBECONFIG_DIR}/config" && ! -f "${KUBECONFIG_FILE}" ]]; then
  mv "${KUBECONFIG_DIR}/config" "${KUBECONFIG_FILE}"
fi

chmod 600 "${KUBECONFIG_FILE}"

log::step 3 "Merging kubeconfig"
k8s::merge_kubeconfig "${KUBECONFIG_FILE}"

log::success "Kubeconfig ready. Test with: kubectl --kubeconfig=${KUBECONFIG_FILE} get nodes"
