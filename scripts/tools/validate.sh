#!/usr/bin/env bash
# Non-destructive validation for the four-repository CSOC workspace.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"
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
done < <(find "${REPO_ROOT}" -type f \( -name '*.sh' -o -name '*.bash' \) \
  -not -path '*/.git/*' -print0)

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
bash "${REPO_ROOT}/scripts/tools/scan-secrets.sh"

APP_OF_APPS="${REPO_ROOT}/argocd/app-of-apps.yaml"
[[ $(yq -r '.spec.source.path' "${APP_OF_APPS}") == argocd ]] \
  || log::die "App-of-Apps source path must be spec.source.path"
[[ $(yq -r '.spec.source.directory.path // ""' "${APP_OF_APPS}") == "" ]] \
  || log::die "App-of-Apps source path must not be nested under spec.source.directory"
for application_file in "${REPO_ROOT}"/argocd/apps/*.yaml; do
  if [[ $(yq -r '.spec.source.directory != null' "${application_file}") == true \
     && $(yq -r '.spec.source.path // ""' "${application_file}") == "" ]]; then
    log::die "Git directory Application is missing spec.source.path: ${application_file}"
  fi
done
PLATFORM_PROJECT="${REPO_ROOT}/argocd/projects/csoc-platform.yaml"
for namespace in cert-manager kube-system capi-operator-system; do
  yq -e \
    ".spec.destinations[] | select(.server == \"https://kubernetes.default.svc\" and .namespace == \"${namespace}\")" \
    "${PLATFORM_PROJECT}" >/dev/null \
    || log::die "CSOC platform project does not permit required namespace: ${namespace}"
done
for kind in MutatingWebhookConfiguration ValidatingWebhookConfiguration; do
  yq -e \
    ".spec.clusterResourceWhitelist[] | select(.group == \"admissionregistration.k8s.io\" and .kind == \"${kind}\")" \
    "${PLATFORM_PROJECT}" >/dev/null \
    || log::die "CSOC platform project does not permit required admission resource: ${kind}"
done
yq -e \
  '.spec.clusterResourceWhitelist[] | select(.group == "infrastructure.cluster.x-k8s.io" and .kind == "OpenStackClusterIdentity")' \
  "${PLATFORM_PROJECT}" >/dev/null \
  || log::die "CSOC platform project does not permit the cluster-scoped CAPO identity"
CAPI_VALUES=$(yq -r '.spec.source.helm.values' "${REPO_ROOT}/argocd/apps/capi-operator.yaml")
[[ $(yq -r '.core.cluster-api.manager.featureGates.ClusterTopology // false' <<<"${CAPI_VALUES}") == true ]] \
  || log::die "CAPI ClusterTopology feature gate must remain enabled"
[[ $(yq -r '.core.cluster-api.manager.featureGates.ClusterResourceSet // ""' <<<"${CAPI_VALUES}") == "" ]] \
  || log::die "CAPI ${CAPI_VERSION} no longer accepts the ClusterResourceSet feature-gate flag"

RGD="${WORKSPACE_ROOT}/js-poc-csoc-platform-apis/rgds/spoke-cluster.rgd.yaml"
[[ $(yq -r '.spec.schema.apiVersion' "${RGD}") == v1alpha1 ]] \
  || log::die "SpokeCluster RGD must use the current KRO schema apiVersion form"
[[ $(yq -r '.spec.schema.group' "${RGD}") == csoc.js2.org ]] \
  || log::die "SpokeCluster RGD group is incorrect"
if rg --line-number 'default\(' "${RGD}"; then
  log::die "Legacy KRO SimpleSchema default syntax detected"
fi
EXPECTED_WORKER_REPLICAS='${schema.spec.kubernetes.minNodes}'
EXPECTED_WORKER_MIN='${string(schema.spec.kubernetes.minNodes)}'
EXPECTED_WORKER_MAX='${string(schema.spec.kubernetes.maxNodes)}'
[[ $(yq -r '.spec.resources[] | select(.id == "machinedeployment") | .template.spec.replicas' "${RGD}") \
   == "${EXPECTED_WORKER_REPLICAS}" ]] \
  || log::die "Spoke MachineDeployment must start at the declared minimum node count"
[[ $(yq -r '.spec.resources[] | select(.id == "machinedeployment") | .template.metadata.annotations."cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size"' "${RGD}") \
   == "${EXPECTED_WORKER_MIN}" ]] \
  || log::die "Spoke MachineDeployment minimum autoscaling annotation is incorrect"
[[ $(yq -r '.spec.resources[] | select(.id == "machinedeployment") | .template.metadata.annotations."cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size"' "${RGD}") \
   == "${EXPECTED_WORKER_MAX}" ]] \
  || log::die "Spoke MachineDeployment maximum autoscaling annotation is incorrect"
EXPECTED_NODE_CIDR='${schema.spec.infrastructure.nodeCIDR}'
[[ $(yq -r '.spec.resources[] | select(.id == "openstackcluster") | .template.spec.managedSubnets[0].cidr' "${RGD}") \
   == "${EXPECTED_NODE_CIDR}" ]] \
  || log::die "Spoke OpenStackCluster must provision its declared node CIDR through managedSubnets"
[[ $(yq -r '.spec.resources[] | select(.id == "openstackcluster") | .template.spec.dnsNameservers // ""' "${RGD}") \
   == "" ]] \
  || log::die "CAPO no longer supports top-level OpenStackCluster dnsNameservers"
[[ $(yq -r '.spec.resources[] | select(.id == "openstackcluster") | .template.spec.managedSubnets[0].dnsNameservers[0]' "${RGD}") \
   == '${schema.spec.infrastructure.dnsNameserver}' ]] \
  || log::die "Spoke DNS nameserver must be configured on the CAPO managed subnet"

log::step 3 "Validating fleet bounds, names, and network declarations"
mapfile -t cluster_files < <(find "${WORKSPACE_ROOT}/js-poc-csoc-fleet/customers" \
  -type f -name cluster.yaml | sort)
declare -A cluster_names=()
declare -A node_cidrs=()
for cluster_file in "${cluster_files[@]}"; do
  cluster_name=$(yq -er '.metadata.name' "${cluster_file}")
  [[ -z "${cluster_names[${cluster_name}]:-}" ]] \
    || log::die "Duplicate SpokeCluster name '${cluster_name}'"
  cluster_names[${cluster_name}]="${cluster_file}"
  min_nodes=$(yq -er '.spec.kubernetes.minNodes' "${cluster_file}")
  max_nodes=$(yq -er '.spec.kubernetes.maxNodes' "${cluster_file}")
  (( min_nodes >= 1 && min_nodes <= max_nodes )) \
    || log::die "Invalid worker bounds in ${cluster_file}: ${min_nodes}..${max_nodes}"
  node_cidr=$(yq -er '.spec.infrastructure.nodeCIDR' "${cluster_file}")
  [[ ${node_cidr} =~ ^(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3})/([8-9]|[12][0-9]|3[0-2])$ ]] \
    || log::die "Spoke node CIDR must be an explicit RFC1918 IPv4 CIDR in ${cluster_file}: ${node_cidr}"
  [[ -z "${node_cidrs[${node_cidr}]:-}" ]] \
    || log::die "Duplicate spoke node CIDR '${node_cidr}'"
  node_cidrs[${node_cidr}]="${cluster_file}"
done

log::step 4 "Rendering Kustomize and Helm packages"
REGISTRATION_RENDER=$(kubectl kustomize "${REPO_ROOT}/cluster-registration")
rg -q 'confirm-reachability\.sh' <<<"${REGISTRATION_RENDER}" \
  || log::die "Cluster registration does not package the shared reachability checker"
rg -q 'kubectl get spokecluster --all-namespaces' <<<"${REGISTRATION_RENDER}" \
  || log::die "Cluster registration does not discover every spoke"
rg -q -- '--minimum-ready "\$minimum_ready"' <<<"${REGISTRATION_RENDER}" \
  || log::die "Cluster registration does not enforce each spoke minimum Ready-node count"
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

log::step 5 "Running local lifecycle and reachability regression tests"
bash "${REPO_ROOT}/tests/magnum/run.sh"
bash "${REPO_ROOT}/tests/registration/run.sh"

log::success "All non-destructive validation checks passed."
