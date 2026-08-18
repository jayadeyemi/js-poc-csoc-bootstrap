#!/usr/bin/env bash
# Full orchestration: build container → Magnum → CAPI bootstrap → Argo CD install → GitOps hand-off.
# Each step is idempotent; re-running is safe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"

log::info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log::info " Jetstream2 CSOC Bootstrap"
log::info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

log::step A "Build management container"
bash "${REPO_ROOT}/scripts/container/build.sh"

log::step B "Provision Magnum management cluster"
bash "${REPO_ROOT}/scripts/magnum/provision.sh"

log::step C "Wait for Magnum cluster to become active"
bash "${REPO_ROOT}/scripts/magnum/wait.sh"

log::step D "Retrieve management cluster kubeconfig"
bash "${REPO_ROOT}/scripts/magnum/kubeconfig.sh"

log::step E "Bootstrap CAPI + CAPO controllers (pre-GitOps, one-time)"
bash "${REPO_ROOT}/scripts/capi/install-controllers.sh"
bash "${REPO_ROOT}/scripts/capi/create-cloud-secret.sh"

log::step F "Install Argo CD on management cluster"
bash "${REPO_ROOT}/scripts/argocd/install.sh"

log::step G "Apply App-of-Apps — hand off management cluster to GitOps"
bash "${REPO_ROOT}/scripts/argocd/bootstrap-apps.sh"

log::success "Bootstrap complete. Git is now the control plane."
log::info   "Add spoke clusters by opening PRs to js-poc-csoc-fleet."
