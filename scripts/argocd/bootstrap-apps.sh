#!/usr/bin/env bash
# Apply the App-of-Apps to hand the management cluster off to GitOps.
# After this script runs, Git is the control plane — use PRs, not kubectl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"

APP_OF_APPS="${REPO_ROOT}/argocd/app-of-apps.yaml"

log::step 1 "Verifying Argo CD is running"
kubectl get deployment argocd-server -n argocd >/dev/null \
  || log::die "Argo CD not found. Run 'make argocd-install' first."

log::step 2 "Applying App-of-Apps"
kubectl apply --server-side -f "${APP_OF_APPS}" -n argocd

log::step 3 "Waiting for initial sync"
# Give Argo time to process the App-of-Apps before checking status
sleep 10
kubectl wait application csoc-app-of-apps \
  --namespace argocd \
  --for=condition=Healthy \
  --timeout=300s 2>/dev/null \
  || log::warn "App-of-Apps not yet healthy — it may still be syncing."

log::success "App-of-Apps applied. GitOps is now in control."
log::info "  Watch sync: kubectl get applications -n argocd"
log::info "  Argo UI:    NodePort 30443 on any cluster node"
log::info ""
log::info "Adding a spoke cluster is now a PR to js-poc-csoc-fleet."
