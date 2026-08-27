#!/usr/bin/env bash
# Inner bootstrap pipeline; invoked inside the pinned management container.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
csoc::load_profile "${REPO_ROOT}"
export KUBECONFIG="${KUBECONFIG:-${MAGNUM_KUBECONFIG_DIR}/config}"

log::info "CSOC profile: ${CSOC_PROFILE} (${MAGNUM_CLUSTER_NAME})"

log::step A "Validate the coordinated workspace"
bash "${REPO_ROOT}/scripts/tools/validate.sh"
log::step B "Preflight and provision the guide-exact Magnum cluster"
bash "${REPO_ROOT}/scripts/bootstrap/magnum/preflight.sh"
bash "${REPO_ROOT}/scripts/bootstrap/magnum/provision.sh"
log::step C "Wait for complete and HEALTHY Magnum state"
bash "${REPO_ROOT}/scripts/bootstrap/magnum/wait.sh"
log::step C "Reconcile default worker node-group bounds"
bash "${REPO_ROOT}/scripts/bootstrap/magnum/configure-nodegroup.sh"
log::step D "Retrieve certificate kubeconfig and verify the management cluster"
bash "${REPO_ROOT}/scripts/bootstrap/magnum/kubeconfig.sh"
bash "${REPO_ROOT}/scripts/bootstrap/magnum/verify.sh"
if [[ "${MAGNUM_AUTO_SCALING_ENABLED}" == true ]]; then
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/verify-autoscaling.sh"
else
  log::info "Autoscaling acceptance is deferred; ${CSOC_PROFILE} uses fixed worker bounds"
fi
log::step E "Install Argo CD"
bash "${REPO_ROOT}/scripts/bootstrap/argocd/install.sh"
log::step E "Manually validate manifests before enabling Argo reconciliation"
bash "${REPO_ROOT}/scripts/bootstrap/argocd/manual-smoke-test.sh"
log::step F "Load one separate restricted credential for each active spoke account"
FLEET_ROOT="${FLEET_ROOT:-$(cd "${REPO_ROOT}/../js-poc-csoc-fleet" && pwd)}"
if [[ "${CSOC_FLEET_ENABLED}" == true ]]; then
  mapfile -t active_identities < <(
    find "${FLEET_ROOT}/${CSOC_FLEET_PATH}/accounts" -type f \
      -name identity-config.yaml -print0 \
      | xargs -0 -r yq -r '.metadata.name' | sort -u
  )
  for identity in "${active_identities[@]}"; do
    bash "${REPO_ROOT}/scripts/bootstrap/credentials/create-runtime-cloud-secret.sh" "${identity}"
  done
  if (( ${#active_identities[@]} == 0 )); then
    log::info "No spoke accounts are active; no spoke credentials were loaded"
  fi
else
  log::info "${CSOC_PROFILE} intentionally has no fleet Application or spoke credentials"
fi
log::step G "Apply App-of-Apps and wait for GitOps controllers"
bash "${REPO_ROOT}/scripts/bootstrap/argocd/bootstrap-apps.sh"
log::success "Bootstrap complete. Git is now the control plane."
