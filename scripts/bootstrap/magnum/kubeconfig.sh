#!/usr/bin/env bash
# Retrieve the kubeconfig for the Magnum cluster and merge it into ~/.kube/config.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/openstack.bash"
source "${REPO_ROOT}/scripts/lib/k8s.bash"
source "${REPO_ROOT}/scripts/lib/credentials.bash"

source "${REPO_ROOT}/iac/magnum/cluster.env"

KUBECONFIG_DIR="${MAGNUM_KUBECONFIG_DIR:-${HOME}/.kube}"
KUBECONFIG_FILE="${KUBECONFIG_DIR}/${MAGNUM_CLUSTER_NAME}.yaml"
STATE_FILE="${MAGNUM_STATE_FILE:-${REPO_ROOT}/.state/magnum-cluster.json}"
credentials::configure_magnum
CLUSTER_ID=$(os::verify_owned_cluster "${STATE_FILE}" "${MAGNUM_CLUSTER_NAME}")
export SHELL="${SHELL:-/bin/bash}"

log::step 1 "Verifying cluster is active"
status=$(os::cluster_status "${CLUSTER_ID}")
[[ "${status}" == "CREATE_COMPLETE" || "${status}" == "UPDATE_COMPLETE" ]] \
  || log::die "Cluster is not active (status: ${status}). Run 'make magnum-wait' first."

mkdir -p "${KUBECONFIG_DIR}"
chmod 700 "${KUBECONFIG_DIR}"
STAGING_DIR=$(mktemp -d "${KUBECONFIG_DIR}/.magnum-kubeconfig.XXXXXX")
cleanup() {
  rm -rf -- "${STAGING_DIR}"
}
trap cleanup EXIT

log::step 2 "Fetching kubeconfig → ${KUBECONFIG_FILE}"
openstack coe cluster config "${CLUSTER_ID}" \
  --use-certificate \
  --output-certs \
  --force \
  --dir "${STAGING_DIR}"

FETCHED_CONFIG=$(find "${STAGING_DIR}" -maxdepth 1 -type f \
  \( -name config -o -name '*.yaml' -o -name '*.conf' \) -print -quit)
[[ -n "${FETCHED_CONFIG}" ]] || log::die "Magnum did not produce a kubeconfig"
kubectl --kubeconfig="${FETCHED_CONFIG}" config view --raw >/dev/null \
  || log::die "Magnum produced an invalid kubeconfig"

install -m 600 "${FETCHED_CONFIG}" "${KUBECONFIG_FILE}"

log::step 3 "Merging kubeconfig"
k8s::merge_kubeconfig "${KUBECONFIG_FILE}"

log::success "Kubeconfig ready. Test with: kubectl --kubeconfig=${KUBECONFIG_FILE} get nodes"
