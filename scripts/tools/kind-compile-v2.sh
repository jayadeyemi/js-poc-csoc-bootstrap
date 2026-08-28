#!/usr/bin/env bash
# Reproducible local KRO compilation gate. The kind cluster is intentionally retained.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/versions.env"

[[ "${CSOC_KIND_COMPILE_APPROVED:-false}" == true ]] || {
  echo "set CSOC_KIND_COMPILE_APPROVED=true to create/update the local csoc-v2-compile kind cluster" >&2
  exit 1
}
for command_name in curl docker helm jq kind kubectl yq; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "missing ${command_name}" >&2; exit 1; }
done

cluster_name=csoc-v2-compile
context="kind-${cluster_name}"
if ! kind get clusters | grep -Fx "${cluster_name}" >/dev/null; then
  kind create cluster --name "${cluster_name}" --image kindest/node:v1.34.0
fi
compile_dir=$(mktemp -d)
trap 'rm -rf -- "${compile_dir}"' EXIT HUP INT TERM
kind get kubeconfig --name "${cluster_name}" >"${compile_dir}/kubeconfig"
export KUBECONFIG="${compile_dir}/kubeconfig"

curl -fsSL "https://github.com/kubernetes-sigs/cluster-api/releases/download/v${CAPI_VERSION}/core-components.yaml" -o "${compile_dir}/capi.yaml"
curl -fsSL "https://github.com/kubernetes-sigs/cluster-api/releases/download/v${CAPI_VERSION}/bootstrap-components.yaml" -o "${compile_dir}/bootstrap.yaml"
curl -fsSL "https://github.com/kubernetes-sigs/cluster-api/releases/download/v${CAPI_VERSION}/control-plane-components.yaml" -o "${compile_dir}/control-plane.yaml"
curl -fsSL "https://github.com/kubernetes-sigs/cluster-api-provider-openstack/releases/download/v${CAPO_VERSION}/infrastructure-components.yaml" -o "${compile_dir}/capo.yaml"
curl -fsSL "https://raw.githubusercontent.com/k-orc/openstack-resource-controller/v${ORC_VERSION}/dist/install.yaml" -o "${compile_dir}/orc.yaml"

helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version "v${CERT_MANAGER_VERSION}" --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait --timeout=5m >/dev/null

# Release component YAML is normally rendered by clusterctl. Resolve its
# shell-style default placeholders so the local gate runs the real webhooks.
for component in capi bootstrap control-plane capo; do
  sed -E -i 's/\$\{[A-Za-z_][A-Za-z0-9_]*:=([^}]*)\}/\1/g' "${compile_dir}/${component}.yaml"
  ! rg -n '\$\{' "${compile_dir}/${component}.yaml" \
    || { echo "unresolved release placeholder in ${component}" >&2; exit 1; }
  kubectl apply --server-side --force-conflicts --field-manager=csoc-v2-kind-components \
    -f "${compile_dir}/${component}.yaml" >/dev/null
done
yq eval-all 'select(.kind == "CustomResourceDefinition")' "${compile_dir}/orc.yaml" \
  | kubectl apply --server-side --force-conflicts --field-manager=csoc-v2-kind-crds -f - >/dev/null

for deployment in \
  capi-system/capi-controller-manager \
  capi-kubeadm-bootstrap-system/capi-kubeadm-bootstrap-controller-manager \
  capi-kubeadm-control-plane-system/capi-kubeadm-control-plane-controller-manager \
  capo-system/capo-controller-manager; do
  kubectl -n "${deployment%/*}" rollout status "deployment/${deployment#*/}" --timeout=5m
done
helm template argocd argo-cd --repo https://argoproj.github.io/argo-helm \
  --version "${ARGOCD_CHART_VERSION}" --include-crds \
  | yq eval-all 'select(.kind == "CustomResourceDefinition")' \
  | kubectl apply --server-side --force-conflicts --field-manager=csoc-v2-kind-crds -f - >/dev/null

kubectl apply --server-side --force-conflicts --field-manager=csoc-v2-kind-rbac -f "${REPO_ROOT}/controllers/kro-v2-rbac.yaml" >/dev/null
helm upgrade --install kro oci://registry.k8s.io/kro/charts/kro \
  --version "${KRO_VERSION}" --namespace kro-system --create-namespace --set rbac.mode=aggregation >/dev/null
kubectl -n kro-system rollout status deployment/kro --timeout=180s

CSOC_V2_SERVER_DRY_RUN_APPROVED=true "${REPO_ROOT}/scripts/tools/server-dry-run-v2.sh"
CSOC_V2_ACTIVATION_APPROVED=true CSOC_EXPECTED_CONTEXT="${context}" \
  bash "${REPO_ROOT}/scripts/tools/activate-v2-rgds.sh"
CSOC_V2_REPLICAS_TEST_APPROVED=true CSOC_EXPECTED_CONTEXT="${context}" \
  bash "${REPO_ROOT}/scripts/tools/test-v2-replicas-ownership.sh"

echo "local ${cluster_name} compile cluster is retained for inspection"
