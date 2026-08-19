#!/usr/bin/env bash
# Non-destructive validation for the four-repository CSOC workspace.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"
source "${REPO_ROOT}/versions.env"

for command_name in bash git helm jq kubectl rg yq; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || log::die "Required validation command not found: ${command_name}"
done

repositories=(
  "${REPO_ROOT}"
  "${WORKSPACE_ROOT}/js-poc-csoc-platform-apis"
  "${WORKSPACE_ROOT}/js-poc-csoc-fleet"
  "${WORKSPACE_ROOT}/js-poc-csoc-app-catalog"
)

log::step 1 "Checking patches, Bash, YAML, and JSON"
for repository in "${repositories[@]}"; do
  [[ -d "${repository}/.git" ]] || log::die "Expected sibling repository not found: ${repository}"
  git -C "${repository}" diff --check
done

while IFS= read -r -d '' script; do
  bash -n "${script}"
done < <(find "${REPO_ROOT}" -type f -name '*.sh' -not -path '*/.git/*' -print0)

for repository in "${repositories[@]}"; do
  while IFS= read -r -d '' yaml_file; do
    yq eval '.' "${yaml_file}" >/dev/null
  done < <(find "${repository}" -type f \( -name '*.yaml' -o -name '*.yml' \) \
    -not -path '*/.git/*' -not -path '*/credentials/*' -print0)
  while IFS= read -r -d '' json_file; do
    jq empty "${json_file}"
  done < <(find "${repository}" -type f -name '*.json' -not -path '*/.git/*' -print0)
done

log::step 2 "Checking ownership boundaries and secret hygiene"
if rg --line-number 'clusterctl[[:space:]]+(init|generate|apply|get kubeconfig)' \
  "${REPO_ROOT}/scripts" "${REPO_ROOT}/Makefile"; then
  log::die "Direct clusterctl lifecycle path detected"
fi
if rg --line-number 'coe cluster template (create|update|delete)' "${REPO_ROOT}/scripts"; then
  log::die "Magnum template mutation detected"
fi
bash "${REPO_ROOT}/scripts/security/scan-secrets.sh"

RGD="${WORKSPACE_ROOT}/js-poc-csoc-platform-apis/rgds/spoke-cluster.rgd.yaml"
[[ $(yq -r '.spec.schema.apiVersion' "${RGD}") == v1alpha1 ]] \
  || log::die "SpokeCluster RGD must use the current KRO schema apiVersion form"
[[ $(yq -r '.spec.schema.group' "${RGD}") == csoc.js2.org ]] \
  || log::die "SpokeCluster RGD group is incorrect"
if rg --line-number 'default\(' "${RGD}"; then
  log::die "Legacy KRO SimpleSchema default syntax detected"
fi

log::step 3 "Validating fleet bounds and unique names"
mapfile -t cluster_files < <(find "${WORKSPACE_ROOT}/js-poc-csoc-fleet/customers" \
  -type f -name cluster.yaml | sort)
declare -A cluster_names=()
for cluster_file in "${cluster_files[@]}"; do
  cluster_name=$(yq -er '.metadata.name' "${cluster_file}")
  [[ -z "${cluster_names[${cluster_name}]:-}" ]] \
    || log::die "Duplicate SpokeCluster name '${cluster_name}'"
  cluster_names[${cluster_name}]="${cluster_file}"
  min_nodes=$(yq -er '.spec.kubernetes.minNodes' "${cluster_file}")
  max_nodes=$(yq -er '.spec.kubernetes.maxNodes' "${cluster_file}")
  (( min_nodes >= 1 && min_nodes <= max_nodes )) \
    || log::die "Invalid worker bounds in ${cluster_file}: ${min_nodes}..${max_nodes}"
done

log::step 4 "Rendering Kustomize and Helm packages"
while IFS= read -r -d '' kustomization; do
  kubectl kustomize "$(dirname "${kustomization}")" >/dev/null
done < <(find "${WORKSPACE_ROOT}/js-poc-csoc-app-catalog" -type f \
  -name kustomization.yaml -print0)

render_dir=$(mktemp -d)
trap 'rm -rf -- "${render_dir}"' EXIT
yq -r '.spec.source.helm.values' "${REPO_ROOT}/argocd/apps/capi-operator.yaml" \
  >"${render_dir}/capi-operator-values.yaml"
helm template capi-operator cluster-api-operator \
  --repo https://kubernetes-sigs.github.io/cluster-api-operator \
  --version "${CAPI_OPERATOR_VERSION}" \
  --namespace capi-operator-system \
  --values "${render_dir}/capi-operator-values.yaml" >/dev/null
helm template argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version "${ARGOCD_CHART_VERSION}" \
  --namespace argocd \
  --values "${REPO_ROOT}/iac/argocd/values.yaml" >/dev/null
helm template cert-manager cert-manager \
  --repo https://charts.jetstack.io \
  --version "v${CERT_MANAGER_VERSION}" \
  --namespace cert-manager \
  --set crds.enabled=true >/dev/null
helm template kro oci://registry.k8s.io/kro/charts/kro \
  --version "${KRO_VERSION}" \
  --namespace kro-system >/dev/null

for addon_id in calico openstackccm cindercsi; do
  yq -r ".spec.resources[] | select(.id == \"${addon_id}\") | .template.spec.valuesTemplate" \
    "${RGD}" \
    | sed \
        -e 's/{{ index .Cluster.spec.clusterNetwork.pods.cidrBlocks 0 }}/192.168.0.0\/16/g' \
        -e 's/{{ .Cluster.metadata.name }}/validation-cluster/g' \
    >"${render_dir}/${addon_id}-values.yaml"
done
helm template calico tigera-operator \
  --repo https://docs.tigera.io/calico/charts \
  --version "v${CALICO_VERSION}" \
  --namespace tigera-operator \
  --values "${render_dir}/calico-values.yaml" >/dev/null
helm template openstack-ccm openstack-cloud-controller-manager \
  --repo https://kubernetes.github.io/cloud-provider-openstack \
  --version "${OPENSTACK_CCM_CHART_VERSION}" \
  --namespace kube-system \
  --values "${render_dir}/openstackccm-values.yaml" >/dev/null
helm template cinder-csi openstack-cinder-csi \
  --repo https://kubernetes.github.io/cloud-provider-openstack \
  --version "${OPENSTACK_CINDER_CSI_CHART_VERSION}" \
  --namespace kube-system \
  --values "${render_dir}/cindercsi-values.yaml" >/dev/null

log::step 5 "Running local Magnum lifecycle regression tests"
bash "${REPO_ROOT}/tests/magnum/run.sh"

log::success "All non-destructive validation checks passed."
