#!/usr/bin/env bash
# Manually exercise the controller install path and validate every Argo manifest
# against the live API before the App-of-Apps enables reconciliation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
source "${REPO_ROOT}/versions.env"
csoc::load_profile "${REPO_ROOT}"
export KUBECONFIG="${KUBECONFIG:-${MAGNUM_KUBECONFIG_DIR}/config}"

SMOKE_NAMESPACE=cert-manager
SMOKE_RELEASE=cert-manager
GATE_CONFIGMAP=argocd-manual-manifest-gate
smoke_installed=false

cleanup() {
  if [[ "${smoke_installed}" == true ]]; then
    log::info "Removing the temporary cert-manager smoke release"
    helm uninstall "${SMOKE_RELEASE}" --namespace "${SMOKE_NAMESPACE}" \
      --wait --timeout 3m >/dev/null 2>&1 || true
    kubectl delete namespace "${SMOKE_NAMESPACE}" \
      --ignore-not-found=true --wait --timeout=120s >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

log::step 1 "Confirming Argo API types exist but no GitOps applications are active"
kubectl wait crd applications.argoproj.io \
  --for=condition=Established --timeout=60s >/dev/null
if kubectl get configmap "${GATE_CONFIGMAP}" -n argocd >/dev/null 2>&1; then
  log::success "Manual pre-handoff manifest gate was already recorded"
  exit 0
fi
if kubectl get application -n argocd --no-headers 2>/dev/null \
    | grep -v -E '^[[:space:]]*$' >/dev/null; then
  log::die "Argo Applications already exist; refusing a pre-handoff smoke test"
fi
if kubectl get namespace "${SMOKE_NAMESPACE}" >/dev/null 2>&1 \
    || kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
  log::die "cert-manager resources already exist; refusing to adopt or remove them"
fi

log::step 2 "Installing temporary cert-manager ${CERT_MANAGER_VERSION}"
helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm repo update >/dev/null
helm upgrade --install "${SMOKE_RELEASE}" jetstack/cert-manager \
  --namespace "${SMOKE_NAMESPACE}" \
  --version "v${CERT_MANAGER_VERSION}" \
  --set crds.enabled=true \
  --set crds.keep=false \
  --create-namespace \
  --wait \
  --timeout 5m
smoke_installed=true

log::step 3 "Waiting for the cert-manager API types"
for crd in \
  certificates.cert-manager.io \
  certificaterequests.cert-manager.io \
  clusterissuers.cert-manager.io \
  issuers.cert-manager.io; do
  kubectl wait crd "${crd}" --for=condition=Established --timeout=120s >/dev/null
done

log::step 4 "Validating ${CSOC_PROFILE} Argo manifests with server-side dry runs"
kubectl apply --dry-run=server --server-side -f "${REPO_ROOT}/argocd/projects" >/dev/null
if [[ "${CSOC_PROFILE}" == prod ]]; then
  kubectl apply --dry-run=server --server-side -f "${REPO_ROOT}/argocd/prod/apps" >/dev/null
else
  kubectl apply --dry-run=server --server-side -f "${REPO_ROOT}/argocd/apps" >/dev/null
fi
kubectl apply --dry-run=server --server-side -f "${CSOC_ARGO_ROOT_MANIFEST}" >/dev/null

cleanup
smoke_installed=false
trap - EXIT

if kubectl get namespace "${SMOKE_NAMESPACE}" >/dev/null 2>&1 \
    || kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
  log::die "Temporary cert-manager resources remain after cleanup"
fi
kubectl create configmap "${GATE_CONFIGMAP}" -n argocd \
  --from-literal="validated-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --from-literal="cert-manager-version=${CERT_MANAGER_VERSION}" \
  --dry-run=client -o yaml \
  | kubectl apply --server-side -f - >/dev/null
log::success "Manual pre-handoff manifest smoke test passed and was cleaned up"
