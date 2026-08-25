#!/usr/bin/env bash
# Manually exercise the controller install path and validate every Argo manifest
# against the live API before the App-of-Apps enables reconciliation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
CATALOG_ROOT="${APP_CATALOG_ROOT:-${WORKSPACE_ROOT}/js-poc-csoc-app-catalog}"
FLEET_ROOT="${FLEET_ROOT:-${WORKSPACE_ROOT}/js-poc-csoc-fleet}"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
source "${REPO_ROOT}/versions.env"
csoc::load_profile "${REPO_ROOT}"
export KUBECONFIG="${KUBECONFIG:-${MAGNUM_KUBECONFIG_DIR}/config}"

SMOKE_NAMESPACE=cert-manager
SMOKE_RELEASE=cert-manager
GATE_CONFIGMAP=argocd-manual-manifest-gate
smoke_installed=false
SOURCE_ROOT=$(mktemp -d)

cleanup() {
  if [[ "${smoke_installed}" == true ]]; then
    log::info "Removing the temporary cert-manager smoke release"
    helm uninstall "${SMOKE_RELEASE}" --namespace "${SMOKE_NAMESPACE}" \
      --wait --timeout 3m >/dev/null 2>&1 || true
    kubectl delete namespace "${SMOKE_NAMESPACE}" \
      --ignore-not-found=true --wait --timeout=120s >/dev/null 2>&1 || true
  fi
  rm -rf -- "${SOURCE_ROOT}"
}
trap cleanup EXIT

archive_revision() {
  local repository=$1 revision=$2 destination=$3
  mkdir -p "${destination}"
  git -C "${repository}" fetch --quiet origin \
    "+refs/heads/${revision}:refs/remotes/origin/${revision}" \
    || log::die "Required Git branch is unavailable: ${repository}@${revision}"
  git -C "${repository}" archive "refs/remotes/origin/${revision}" | tar -x -C "${destination}"
}

log::step 1 "Archiving the exact configured Git revisions"
BOOTSTRAP_SOURCE="${SOURCE_ROOT}/bootstrap"
archive_revision "${REPO_ROOT}" "${CSOC_BOOTSTRAP_REVISION}" "${BOOTSTRAP_SOURCE}"
archive_revision "${CATALOG_ROOT}" "${CSOC_CATALOG_REVISION}" "${SOURCE_ROOT}/catalog"
BOOTSTRAP_COMMIT=$(git -C "${REPO_ROOT}" rev-parse "refs/remotes/origin/${CSOC_BOOTSTRAP_REVISION}")
CATALOG_COMMIT=$(git -C "${CATALOG_ROOT}" rev-parse "refs/remotes/origin/${CSOC_CATALOG_REVISION}")
FLEET_COMMIT=disabled
if [[ "${CSOC_FLEET_ENABLED}" == true ]]; then
  archive_revision "${FLEET_ROOT}" "${CSOC_FLEET_REVISION}" "${SOURCE_ROOT}/fleet"
  FLEET_COMMIT=$(git -C "${FLEET_ROOT}" rev-parse "refs/remotes/origin/${CSOC_FLEET_REVISION}")
fi

log::step 2 "Confirming Argo API types and the controller smoke prerequisite"
kubectl wait crd applications.argoproj.io \
  --for=condition=Established --timeout=60s >/dev/null
if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
  log::info "Existing cert-manager API detected; leaving the reconciled installation untouched"
else
  if kubectl get application -n argocd --no-headers 2>/dev/null \
      | grep -v -E '^[[:space:]]*$' >/dev/null; then
    log::die "Argo Applications exist but the cert-manager API is missing"
  fi
  log::info "Installing temporary cert-manager ${CERT_MANAGER_VERSION}"
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
  for crd in certificates.cert-manager.io certificaterequests.cert-manager.io \
    clusterissuers.cert-manager.io issuers.cert-manager.io; do
    kubectl wait crd "${crd}" --for=condition=Established --timeout=120s >/dev/null
  done
fi

log::step 3 "Validating ${CSOC_PROFILE} Argo manifests from archived revisions"
dry_run_args=(--dry-run=server --server-side --force-conflicts --field-manager=csoc-bootstrap)
kubectl apply "${dry_run_args[@]}" -f "${BOOTSTRAP_SOURCE}/argocd/projects" >/dev/null
if [[ "${CSOC_PROFILE}" == prod ]]; then
  kubectl apply "${dry_run_args[@]}" -f "${BOOTSTRAP_SOURCE}/argocd/prod/apps" >/dev/null
else
  kubectl apply "${dry_run_args[@]}" -f "${BOOTSTRAP_SOURCE}/argocd/apps" >/dev/null
fi
kubectl apply "${dry_run_args[@]}" \
  -f "${BOOTSTRAP_SOURCE}/${CSOC_ARGO_ROOT_MANIFEST_REL}" >/dev/null

if [[ "${smoke_installed}" == true ]]; then
  helm uninstall "${SMOKE_RELEASE}" --namespace "${SMOKE_NAMESPACE}" \
    --wait --timeout 3m >/dev/null
  kubectl delete namespace "${SMOKE_NAMESPACE}" \
    --ignore-not-found=true --wait --timeout=120s >/dev/null
  smoke_installed=false
  if kubectl get namespace "${SMOKE_NAMESPACE}" >/dev/null 2>&1 \
      || kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
    log::die "Temporary cert-manager resources remain after cleanup"
  fi
fi

kubectl create configmap "${GATE_CONFIGMAP}" -n argocd \
  --from-literal="validated-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --from-literal="cert-manager-version=${CERT_MANAGER_VERSION}" \
  --from-literal="profile=${CSOC_PROFILE}" \
  --from-literal="bootstrap-commit=${BOOTSTRAP_COMMIT}" \
  --from-literal="catalog-commit=${CATALOG_COMMIT}" \
  --from-literal="fleet-commit=${FLEET_COMMIT}" \
  --dry-run=client -o yaml \
  | kubectl apply --server-side -f - >/dev/null
log::success "Manual gate recorded exact ${CSOC_PROFILE} source commits"
