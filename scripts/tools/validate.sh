#!/usr/bin/env bash
# Authoritative non-destructive validation for the modular KRO workspace.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
CATALOG_ROOT="${WORKSPACE_ROOT}/js-poc-csoc-app-catalog"
FLEET_ROOT="${WORKSPACE_ROOT}/js-poc-csoc-fleet"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/versions.env"

for command_name in bash git helm jq kubectl rg yq; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || log::die "Required validation command not found: ${command_name}"
done

repositories=("${REPO_ROOT}" "${CATALOG_ROOT}" "${FLEET_ROOT}")

log::step 1 "Checking patches, Bash, YAML, JSON, and secret hygiene"
for repository in "${repositories[@]}"; do
  [[ -d "${repository}/.git" ]] || log::die "Expected repository not found: ${repository}"
  git -C "${repository}" diff --check
  while IFS= read -r -d '' yaml_file; do
    yq eval '.' "${yaml_file}" >/dev/null
  done < <(find "${repository}" -type f \( -name '*.yaml' -o -name '*.yml' \) \
    -not -path '*/.git/*' -not -path '*/scripts/host/credentials/*' -print0)
  while IFS= read -r -d '' json_file; do
    jq empty "${json_file}"
  done < <(find "${repository}" -type f -name '*.json' -not -path '*/.git/*' -print0)
done
while IFS= read -r -d '' script; do
  bash -n "${script}"
done < <(find "${REPO_ROOT}" -type f \( -name '*.sh' -o -name '*.bash' \) \
  -not -path '*/.git/*' -print0)
bash "${REPO_ROOT}/scripts/tools/scan-secrets.sh"

retired_pattern="js-poc-csoc-platform"'-apis|csoc-'"platform|hello-"'csoc'
if rg --line-number "${retired_pattern}" \
    "${REPO_ROOT}" "${CATALOG_ROOT}" "${FLEET_ROOT}" \
    --glob '!**/.git/**' --glob '!agents/**' --glob '!AGENTS.md' \
    --glob '!scripts/tools/validate.sh'; then
  log::die "Retired repository, project, or application references remain"
fi
if rg --line-number 'clusterctl[[:space:]]+(init|generate|apply|get kubeconfig)' \
    "${REPO_ROOT}/scripts" "${REPO_ROOT}/Makefile"; then
  log::die "Direct clusterctl lifecycle path detected"
fi
if rg --line-number 'coe cluster template (create|update|delete)' "${REPO_ROOT}/scripts"; then
  log::die "Magnum template mutation detected"
fi

log::step 2 "Validating the two-project Argo ownership graph"
mapfile -t project_names < <(
  for project_file in "${REPO_ROOT}"/argocd/projects/*.yaml; do
    yq -r '.metadata.name' "${project_file}"
  done | sort
)
[[ "${project_names[*]}" == "csoc-fleet rgds" ]] \
  || log::die "Expected exactly the csoc-fleet and rgds AppProjects"
[[ $(yq -r '.spec.project' "${REPO_ROOT}/argocd/app-of-apps.yaml") == rgds ]] \
  || log::die "App-of-Apps must belong to rgds"
for controller in "${REPO_ROOT}"/controllers/*.yaml; do
  [[ $(yq -r '.spec.project' "${controller}") == rgds ]] \
    || log::die "Controller Application must belong to rgds: ${controller}"
done
[[ $(yq -r '.spec.source.repoURL' "${REPO_ROOT}/argocd/apps/rgds.yaml") \
   == https://github.com/jayadeyemi/js-poc-csoc-app-catalog ]] \
  || log::die "RGDs must be sourced from the app catalog"
[[ $(yq -r '.spec.source.path' "${REPO_ROOT}/argocd/apps/rgds.yaml") == rgds ]] \
  || log::die "RGD Application path is incorrect"
[[ $(yq -r '.spec.source.path' "${REPO_ROOT}/argocd/apps/fleet.yaml") == accounts ]] \
  || log::die "Fleet Application must source accounts/"
[[ ! -e "${REPO_ROOT}/argocd/apps/csoc-baseline.yaml" \
   && ! -d "${REPO_ROOT}/argocd/applicationsets" ]] \
  || log::die "Baseline Applications and ApplicationSets must be removed"
for kind in SpokeCluster SpokeEnvironmentConfig AutoAllocatedSpokeNetwork DedicatedSpokeNetwork; do
  yq -e ".spec.namespaceResourceWhitelist[] | select(.group == \"csoc.js2.org\" and .kind == \"${kind}\")" \
    "${REPO_ROOT}/argocd/projects/csoc-fleet.yaml" >/dev/null \
    || log::die "Fleet project does not permit ${kind}"
done
for kind in ImmutableSpokeConfig SpokeIdentity; do
  yq -e ".spec.clusterResourceWhitelist[] | select(.group == \"csoc.js2.org\" and .kind == \"${kind}\")" \
    "${REPO_ROOT}/argocd/projects/csoc-fleet.yaml" >/dev/null \
    || log::die "Fleet project does not permit cluster-scoped ${kind}"
done
yq -e '.spec.namespaceResourceWhitelist[] | select(.group == "apps.csoc.js2.org" and .kind == "HelloApp")' \
  "${REPO_ROOT}/argocd/projects/csoc-fleet.yaml" >/dev/null \
  || log::die "Fleet project does not permit HelloApp"

log::step 3 "Validating identity and network RGD restrictions"
IDENTITY_RGD="${CATALOG_ROOT}/rgds/cluster/v1/spoke-identity.rgd.yaml"
CONFIG_RGD="${CATALOG_ROOT}/rgds/configmaps/immutable-spoke-config.rgd.yaml"
ENV_CONFIG_RGD="${CATALOG_ROOT}/rgds/configmaps/spoke-environment-config.rgd.yaml"
AUTO_NETWORK_RGD="${CATALOG_ROOT}/rgds/network/auto-allocated-spoke-network.rgd.yaml"
DEDICATED_NETWORK_RGD="${CATALOG_ROOT}/rgds/network/dedicated-spoke-network.rgd.yaml"
SPOKE_RGD="${CATALOG_ROOT}/rgds/cluster/v1/spoke-cluster.rgd.yaml"
HELLO_RGD="${CATALOG_ROOT}/rgds/workloads/hello-app.rgd.yaml"
for rgd in "${CONFIG_RGD}" "${ENV_CONFIG_RGD}" "${IDENTITY_RGD}" "${AUTO_NETWORK_RGD}" \
  "${DEDICATED_NETWORK_RGD}" "${SPOKE_RGD}" "${HELLO_RGD}"; do
  [[ $(yq -r '.apiVersion' "${rgd}") == kro.run/v1alpha1 ]] \
    || log::die "Invalid RGD apiVersion: ${rgd}"
  if rg --line-number 'default\(' "${rgd}"; then
    log::die "Legacy KRO default syntax detected in ${rgd}"
  fi
done
[[ $(yq -r '.spec.schema.scope' "${IDENTITY_RGD}") == Cluster ]] \
  || log::die "SpokeIdentity must be cluster scoped"
[[ $(yq -r '.metadata.name + ":" + .spec.schema.kind' "${IDENTITY_RGD}") == spokeidentity:SpokeIdentity ]] \
  || log::die "The account-boundary API must be SpokeIdentity"
[[ $(yq -r '.spec.schema.kind' "${CONFIG_RGD}") == ImmutableSpokeConfig ]] \
  || log::die "ImmutableSpokeConfig RGD is required"
for config_id in accountconfig infrastructureconfig kubernetesconfig; do
  [[ $(yq -r ".spec.resources[] | select(.id == \"${config_id}\") | .template.immutable" "${CONFIG_RGD}") == true ]] \
    || log::die "ImmutableSpokeConfig output ${config_id} must be immutable"
done
[[ $(yq -r '.spec.schema.spec | keys | join(",")' "${IDENTITY_RGD}") == credentialPolicy ]] \
  || log::die "SpokeIdentity must expose only its restricted credential policy"
[[ $(yq -r '.spec.resources[] | select(.id == "openstackidentity") | .template.spec.secretRef.namespace' "${IDENTITY_RGD}") \
   == '${accountnamespace.metadata.name}' ]] \
  || log::die "CAPO identity secret must be account namespaced"
[[ $(yq -r '.spec.resources[] | select(.id == "openstackidentity") | .template.spec.namespaceSelector.matchLabels."csoc.js2.org/identity"' "${IDENTITY_RGD}") \
   == '${schema.metadata.name}' ]] \
  || log::die "CAPO identity selector must isolate one account"
for config_id in accountconfig infrastructureconfig kubernetesconfig; do
  [[ $(yq -r ".spec.resources[] | select(.id == \"${config_id}\") | .template.immutable" "${IDENTITY_RGD}") == true ]] \
    || log::die "SpokeIdentity output ${config_id} must be immutable"
done
for config_id in networkconfig clusterconfig; do
  [[ $(yq -r ".spec.resources[] | select(.id == \"${config_id}\") | .template.immutable" "${ENV_CONFIG_RGD}") == true ]] \
    || log::die "SpokeEnvironmentConfig output ${config_id} must be immutable"
done
[[ $(yq -r '.spec.schema.spec.kubernetes | keys | join(",")' "${CONFIG_RGD}") \
   == version,controlPlaneCount,controlPlaneFlavor,generalWorkerFlavor ]] \
  || log::die "Immutable Kubernetes config must contain only version, control-plane settings, and the general worker flavor"
[[ $(yq -r '.spec.resources[] | select(.id == "kubernetesconfig") | .template.data | keys | join(",")' "${CONFIG_RGD}") \
   == version,controlPlaneCount,controlPlaneFlavor,generalWorkerFlavor ]] \
  || log::die "Generated Kubernetes ConfigMap contains mutable bounds or unsupported worker classes"
[[ $(yq -r '.spec.schema.spec | keys | join(",")' "${ENV_CONFIG_RGD}") \
   == environment,nodeCIDR,podCIDR,serviceCIDR ]] \
  || log::die "SpokeEnvironmentConfig must not expose a worker class"
[[ $(yq -r '.spec.resources[] | select(.id == "accountpolicy") | .template.spec.paramKind.kind' "${IDENTITY_RGD}") == SpokeIdentity ]] \
  || log::die "Account restrictions must be parameterized by SpokeIdentity"
for network_rgd in "${AUTO_NETWORK_RGD}" "${DEDICATED_NETWORK_RGD}"; do
  [[ $(yq -r '.spec.resources[] | select(.id == "identity") | .externalRef.kind' "${network_rgd}") == SpokeIdentity ]] \
    || log::die "Network graphs must consume SpokeIdentity"
done

for resource_id in network subnet router; do
  [[ $(yq -r ".spec.resources[] | select(.id == \"${resource_id}\") | .template.spec.managementPolicy" "${AUTO_NETWORK_RGD}") == unmanaged ]] \
    || log::die "Auto-allocated ${resource_id} must be unmanaged"
done
[[ $(yq -r '.spec.resources[] | select(.id == "router") | .template.spec.managementPolicy' "${DEDICATED_NETWORK_RGD}") == unmanaged ]] \
  || log::die "Allocation router must never be lifecycle managed"
for resource_id in network subnet; do
  [[ $(yq -r ".spec.resources[] | select(.id == \"${resource_id}\") | .template.spec.managementPolicy" "${DEDICATED_NETWORK_RGD}") == managed ]] \
    || log::die "Dedicated ${resource_id} must be KRO/ORC managed"
  [[ $(yq -r ".spec.resources[] | select(.id == \"${resource_id}\") | .template.spec.managedOptions.onDelete" "${DEDICATED_NETWORK_RGD}") == delete ]] \
    || log::die "Dedicated ${resource_id} cleanup policy is incorrect"
done
[[ $(yq -r '.spec.resources[] | select(.id == "routerinterface") | .template.spec.routerRef' "${DEDICATED_NETWORK_RGD}") \
   == '${router.metadata.name}' ]] \
  || log::die "Dedicated network must attach to the imported allocation router"
for network_rgd in "${AUTO_NETWORK_RGD}" "${DEDICATED_NETWORK_RGD}"; do
  [[ $(yq -r '.spec.resources[] | select(.id == "connection") | .template.immutable' "${network_rgd}") == true ]] \
    || log::die "Network graph must emit an immutable connection ConfigMap"
done
[[ $(yq -r '.spec.resources[] | select(.id == "subnet") | .template.spec.resource.cidr' "${DEDICATED_NETWORK_RGD}") \
   == '${networkconfig.data.nodeCIDR}' ]] \
  || log::die "Dedicated CIDR must come from its immutable input ConfigMap"

log::step 4 "Validating restricted SpokeCluster inputs and CAPI graph"
for forbidden in infrastructure controlPlane network networkRef environment provider; do
  [[ $(yq -r ".spec.schema.spec.${forbidden} // \"\"" "${SPOKE_RGD}") == "" ]] \
    || log::die "Fleet-visible SpokeCluster field is forbidden: ${forbidden}"
done
[[ $(yq -r '.spec.schema.spec | keys | join(",")' "${SPOKE_RGD}") == kubernetes \
   && $(yq -r '.spec.schema.spec.kubernetes | keys | join(",")' "${SPOKE_RGD}") == minNodes,maxNodes ]] \
  || log::die "SpokeCluster must expose only mutable minNodes and maxNodes"
for external_id in accountnamespace identity infrastructureconfig kubernetesconfig clusterconfig networkconnection; do
  yq -e ".spec.resources[] | select(.id == \"${external_id}\") | .externalRef" "${SPOKE_RGD}" >/dev/null \
    || log::die "SpokeCluster is missing external reference ${external_id}"
done
[[ $(yq -r '.spec.resources[] | select(.id == "openstackcluster") | .template.spec.identityRef.name' "${SPOKE_RGD}") \
   == '${identity.metadata.name}' ]] \
  || log::die "SpokeCluster identity must come from SpokeIdentity"
[[ $(yq -r '.spec.resources[] | select(.id == "openstackcluster") | .template.spec.managedSubnets // ""' "${SPOKE_RGD}") == "" ]] \
  || log::die "CAPO must not implicitly create an undeclared spoke network"
[[ $(yq -r '.spec.resources[] | select(.id == "openstackcluster") | .template.spec.network.id' "${SPOKE_RGD}") \
   == '${networkconnection.data.networkID}' ]] \
  || log::die "CAPO network must be sourced from an immutable connection ConfigMap"
[[ $(yq -r '.spec.resources[] | select(.id == "controlplanemachinetemplate") | .template.spec.template.spec.image.id' "${SPOKE_RGD}") \
   == '${infrastructureconfig.data.imageID}' ]] \
  || log::die "Approved image must come from the immutable infrastructure ConfigMap"
[[ $(yq -r '.spec.resources[] | select(.id == "workermachinetemplate") | .template.spec.template.spec.flavor' "${SPOKE_RGD}") \
   == '${kubernetesconfig.data.generalWorkerFlavor}' ]] \
  || log::die "Workers must use the immutable approved general flavor"
[[ $(yq -r '.spec.resources[] | select(.id == "cloudconfigresourceset") | .template.spec.resources[0].name' "${SPOKE_RGD}") \
   == '${identity.metadata.name + "-workload-cloud-config"}' ]] \
  || log::die "Workload credentials must be identity scoped"
[[ $(yq -r '.spec.resources[] | select(.id == "machinedeployment") | .template.spec.replicas // ""' "${SPOKE_RGD}") == "" ]] \
  || log::die "MachineDeployment replicas must remain under autoscaler ownership"
[[ $(yq -r '.spec.resources[] | select(.id == "openstackcluster") | .template.spec.managedSecurityGroups.allowAllInClusterTraffic' "${SPOKE_RGD}") == false ]] \
  || log::die "Spoke security groups must not allow all cluster traffic"

log::step 5 "Validating accounts/test-poc and direct KRO workload delivery"
ACCOUNT_DIR="${FLEET_ROOT}/accounts/test-poc"
[[ -f "${FLEET_ROOT}/accounts/kustomization.yaml" && -f "${ACCOUNT_DIR}/kustomization.yaml" ]] \
  || log::die "Fleet must expose accounts/test-poc as a Kustomize package"
[[ $(yq -r '.kind + ":" + .metadata.name' "${ACCOUNT_DIR}/identity-config.yaml") \
   == ImmutableSpokeConfig:test-poc ]] \
  || log::die "test-poc must own its ImmutableSpokeConfig instance"
[[ $(yq -r '.kind + ":" + .metadata.name' "${ACCOUNT_DIR}/identity.yaml") \
   == SpokeIdentity:test-poc ]] \
  || log::die "test-poc must use the SpokeIdentity API"
for file in spoke-config.yaml network.yaml cluster.yaml hello-app.yaml; do
  [[ $(yq -r '.metadata.namespace' "${ACCOUNT_DIR}/${file}") == spokeclusters-test-poc ]] \
    || log::die "${file} must be isolated in spokeclusters-test-poc"
done
for file in spoke-config.yaml network.yaml cluster.yaml hello-app.yaml; do
  [[ $(yq -r '.metadata.name' "${ACCOUNT_DIR}/${file}") == poc-tenant-dev ]] \
    || log::die "${file} must compose the poc-tenant-dev graph"
done
min_nodes=$(yq -er '.spec.kubernetes.minNodes' "${ACCOUNT_DIR}/cluster.yaml")
max_nodes=$(yq -er '.spec.kubernetes.maxNodes' "${ACCOUNT_DIR}/cluster.yaml")
(( min_nodes >= 1 && min_nodes <= max_nodes && max_nodes <= 4 )) \
  || log::die "Invalid test-poc worker bounds"
[[ $(yq -r '.spec.kubernetes | keys | join(",")' "${ACCOUNT_DIR}/identity-config.yaml") \
   == version,controlPlaneCount,controlPlaneFlavor,generalWorkerFlavor ]] \
  || log::die "test-poc immutable config must not contain scale bounds or unsupported worker classes"
[[ $(yq -r '.spec | keys | join(",")' "${ACCOUNT_DIR}/cluster.yaml") == kubernetes \
   && $(yq -r '.spec.kubernetes | keys | join(",")' "${ACCOUNT_DIR}/cluster.yaml") == minNodes,maxNodes ]] \
  || log::die "test-poc SpokeCluster must contain only mutable worker bounds"
node_cidr=$(yq -er '.spec.nodeCIDR' "${ACCOUNT_DIR}/spoke-config.yaml")
[[ ${node_cidr} =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]] \
  || log::die "Dedicated network CIDR is not RFC1918"
if rg --line-number '(secret(Name|Ref)|applicationCredential|credentialSecret):' "${FLEET_ROOT}/accounts"; then
  log::die "Fleet instances must not name or embed credentials"
fi
if rg --line-number 'SpokeCluster|cluster\.x-k8s\.io|infrastructure\.cluster\.x-k8s\.io' \
    "${REPO_ROOT}/scripts/bootstrap/magnum" "${REPO_ROOT}/scripts/operations/magnum"; then
  log::die "Magnum lifecycle must manage only the CSOC management cluster"
fi
rg -q '<body><h1>Hello from every spoke\.</h1></body>' "${HELLO_RGD}" \
  || log::die "HelloApp RGD message is incorrect"
rg -q 'replicas: \$\{string\(schema\.spec\.replicas\)\}' "${HELLO_RGD}" \
  || log::die "HelloApp must stringify replicas inside its manifest payload"
[[ $(yq -r '.spec.schema.scope' "${HELLO_RGD}") == Namespaced ]] \
  || log::die "HelloApp must be an account-scoped workload graph"
yq -e '.spec.resources[] | select(.id == "resourceset") | .template.kind == "ClusterResourceSet"' \
  "${HELLO_RGD}" >/dev/null || log::die "HelloApp must deploy through CAPI ClusterResourceSet"

log::step 6 "Rendering Kustomize and Helm packages"
while IFS= read -r -d '' kustomization; do
  kubectl kustomize "$(dirname "${kustomization}")" >/dev/null
done < <(find "${CATALOG_ROOT}" "${FLEET_ROOT}" -type f -name kustomization.yaml -print0)

render_dir=$(mktemp -d)
trap 'rm -rf -- "${render_dir}"' EXIT
yq -r '.spec.source.helm.values' "${REPO_ROOT}/controllers/capi-operator.yaml" >"${render_dir}/capi-values.yaml"
helm template capi-operator cluster-api-operator \
  --repo https://kubernetes-sigs.github.io/cluster-api-operator \
  --version "${CAPI_OPERATOR_VERSION}" --namespace capi-operator-system \
  --values "${render_dir}/capi-values.yaml" >/dev/null
helm template argocd argo-cd --repo https://argoproj.github.io/argo-helm \
  --version "${ARGOCD_CHART_VERSION}" --namespace argocd \
  --values "${REPO_ROOT}/iac/argocd/values.yaml" >/dev/null
helm template cert-manager cert-manager --repo https://charts.jetstack.io \
  --version "v${CERT_MANAGER_VERSION}" --namespace cert-manager --set crds.enabled=true >/dev/null
helm template kro oci://registry.k8s.io/kro/charts/kro \
  --version "${KRO_VERSION}" --namespace kro-system >/dev/null

log::step 7 "Running local lifecycle and credential regression tests"
bash "${REPO_ROOT}/tests/magnum/run.sh"
bash "${REPO_ROOT}/tests/credentials/run.sh"

log::success "All modular KRO non-destructive validation checks passed."
