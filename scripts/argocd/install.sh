#!/usr/bin/env bash
# Idempotently install Argo CD via Helm onto the management cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"
source "${REPO_ROOT}/scripts/lib/k8s.sh"
source "${REPO_ROOT}/versions.env"

ARGOCD_NAMESPACE="argocd"
VALUES_FILE="${REPO_ROOT}/iac/argocd/values.yaml"

log::step 1 "Verifying management cluster connectivity"
kubectl cluster-info >/dev/null \
  || log::die "Cannot reach management cluster. Run 'make magnum-kubeconfig' first."

log::step 2 "Ensuring namespace '${ARGOCD_NAMESPACE}'"
k8s::ensure_namespace "${ARGOCD_NAMESPACE}"

log::step 3 "Adding Argo CD Helm repo"
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo update >/dev/null

log::step 4 "Installing / upgrading Argo CD ${ARGOCD_CHART_VERSION}"
helm upgrade --install argocd argo/argo-cd \
  --namespace "${ARGOCD_NAMESPACE}" \
  --version "${ARGOCD_CHART_VERSION}" \
  --values "${VALUES_FILE}" \
  --wait \
  --timeout 10m

log::step 5 "Waiting for Argo CD server to be ready"
kubectl wait deployment argocd-server \
  --namespace "${ARGOCD_NAMESPACE}" \
  --for=condition=Available \
  --timeout=300s

log::success "Argo CD installed."
log::info "  UI:      kubectl -n argocd port-forward svc/argocd-server 8443:443"
log::info "  Password: retrieve explicitly with 'argocd admin initial-password -n argocd'"
log::info "  Next:    run 'make argocd-bootstrap' to apply the App-of-Apps"
