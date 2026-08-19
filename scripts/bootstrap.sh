#!/usr/bin/env bash
# Full orchestration: validate → Magnum → Argo CD → declarative GitOps hand-off.
# Each step is idempotent; re-running is safe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"

log::info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log::info " Jetstream2 CSOC Bootstrap"
log::info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

log::step A "Validate repository and build management container"
bash "${REPO_ROOT}/scripts/validate.sh"
bash "${REPO_ROOT}/scripts/container/build.sh"

log::step B "Run OpenStack preflight and provision Magnum management cluster"
bash "${REPO_ROOT}/scripts/magnum/preflight.sh"
bash "${REPO_ROOT}/scripts/magnum/provision.sh"

log::step C "Wait for Magnum cluster to become active"
bash "${REPO_ROOT}/scripts/magnum/wait.sh"

log::step D "Retrieve management cluster kubeconfig"
bash "${REPO_ROOT}/scripts/magnum/kubeconfig.sh"

log::step E "Install Argo CD on management cluster"
bash "${REPO_ROOT}/scripts/argocd/install.sh"

log::step F "Create CAPO runtime credential secret"
bash "${REPO_ROOT}/scripts/capi/create-cloud-secret.sh"

log::step G "Apply App-of-Apps — Argo installs CAPI, CAPO, ORC, KRO, and addons"
bash "${REPO_ROOT}/scripts/argocd/bootstrap-apps.sh"

log::success "Bootstrap complete. Git is now the control plane."
log::info   "Add spoke clusters by opening PRs to js-poc-csoc-fleet."
