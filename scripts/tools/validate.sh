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
    --glob '!**/.git/**' \
    --glob '!scripts/tools/validate.sh'; then
  log::die "Retired repository, project, or application references remain"
fi
if rg --line-number '^kind:[[:space:]]+ApplicationSet$' \
    "${REPO_ROOT}" "${CATALOG_ROOT}" "${FLEET_ROOT}" \
    --glob '*.yaml' --glob '*.yml' --glob '!**/.git/**'; then
  log::die "Tracked ApplicationSet manifest detected"
fi
if rg --line-number 'clusterctl[[:space:]]+(init|generate|apply|get kubeconfig)' \
    "${REPO_ROOT}/scripts" "${REPO_ROOT}/Makefile"; then
  log::die "Direct clusterctl lifecycle path detected"
fi
if rg --line-number 'coe cluster template (create|update|delete)' "${REPO_ROOT}/scripts"; then
  log::die "Magnum template mutation detected"
fi

log::step 2 "Validating the three-project Argo ownership graph"
for profile_manifest in iac/csoc/profiles/dev.profile iac/csoc/profiles/prod.profile; do
  git -C "${REPO_ROOT}" ls-files --error-unmatch "${profile_manifest}" >/dev/null \
    || log::die "CSOC environment selection must be tracked: ${profile_manifest}"
  if git -C "${REPO_ROOT}" check-ignore -q "${profile_manifest}"; then
    log::die "CSOC environment selection must not be ignored: ${profile_manifest}"
  fi
done
mapfile -t project_names < <(
  for project_file in "${REPO_ROOT}"/argocd/projects/*.yaml; do
    yq -r '.metadata.name' "${project_file}"
  done | sort
)
[[ "${project_names[*]}" == "csoc-baseline csoc-fleet rgds" ]] \
  || log::die "Expected exactly the csoc-baseline, csoc-fleet, and rgds AppProjects"
[[ $(yq -r '.spec.project' "${REPO_ROOT}/argocd/app-of-apps.yaml") == rgds ]] \
  || log::die "App-of-Apps must belong to rgds"
for controller in "${REPO_ROOT}"/controllers/*.yaml; do
  [[ $(yq -r '.spec.project' "${controller}") == rgds ]] \
    || log::die "Controller Application must belong to rgds: ${controller}"
done
for resource in \
  'cert-manager.io:Certificate' \
  'cert-manager.io:Issuer' \
  'operator.cluster.x-k8s.io:AddonProvider' \
  'operator.cluster.x-k8s.io:BootstrapProvider' \
  'operator.cluster.x-k8s.io:ControlPlaneProvider' \
  'operator.cluster.x-k8s.io:CoreProvider' \
  'operator.cluster.x-k8s.io:InfrastructureProvider'; do
  group=${resource%%:*}
  kind=${resource#*:}
  yq -e ".spec.namespaceResourceWhitelist[] | select(.group == \"${group}\" and .kind == \"${kind}\")" \
    "${REPO_ROOT}/argocd/projects/rgds.yaml" >/dev/null \
    || log::die "RGD project does not permit controller resource ${resource}"
done
[[ $(yq -r '.spec.source.repoURL' "${REPO_ROOT}/argocd/apps/rgds.yaml") \
   == https://github.com/jayadeyemi/js-poc-csoc-app-catalog ]] \
  || log::die "RGDs must be sourced from the app catalog"
[[ $(yq -r '.spec.source.path' "${REPO_ROOT}/argocd/apps/rgds.yaml") == rgds ]] \
  || log::die "RGD Application path is incorrect"
[[ $(yq -r '.spec.source.path' "${REPO_ROOT}/argocd/apps/fleet.yaml") == . ]] \
  || log::die "Fleet Application must source the fleet root"
[[ $(yq -r '.spec.source.targetRevision' "${REPO_ROOT}/argocd/apps/rgds.yaml") == main \
   && $(yq -r '.spec.source.targetRevision' "${REPO_ROOT}/argocd/apps/fleet.yaml") == main ]] \
  || log::die "Development RGD and fleet Applications must track main"
[[ $(yq -r '.spec.source.targetRevision' "${REPO_ROOT}/argocd/prod/apps/rgds.yaml") == release/prod \
   && $(yq -r '.spec.source.targetRevision' "${REPO_ROOT}/argocd/prod/apps/controllers.yaml") == release/prod \
   && ! -e "${REPO_ROOT}/argocd/prod/apps/fleet.yaml" ]] \
  || log::die "Production must track release/prod for controllers/RGDs and omit fleet"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
CSOC_PROFILE=dev csoc::load_profile "${REPO_ROOT}"
[[ "${MAGNUM_CLUSTER_NAME}" == js2-mgmt-cluster-2 \
   && "${MAGNUM_MASTER_COUNT}:${MAGNUM_MASTER_FLAVOR}" == 1:m3.quad \
   && "${CSOC_FLEET_ENABLED}" == true ]] \
  || log::die "Development profile does not bind the existing small CSOC"
unset MAGNUM_CLUSTER_NAME MAGNUM_STATE_FILE MAGNUM_KUBECONFIG_DIR MAGNUM_MASTER_COUNT \
  MAGNUM_MASTER_FLAVOR MAGNUM_NODE_COUNT MAGNUM_WORKER_FLAVOR MAGNUM_MIN_NODE_COUNT \
  MAGNUM_MAX_NODE_COUNT MAGNUM_EXPECTED_INITIAL_NODES
CSOC_PROFILE=prod csoc::load_profile "${REPO_ROOT}"
[[ "${MAGNUM_MASTER_COUNT}:${MAGNUM_MASTER_FLAVOR}" == 3:m3.quad \
   && "${CSOC_FLEET_ENABLED}" == false \
   && "${CSOC_CATALOG_REVISION}" == release/prod ]] \
  || log::die "Production profile must freeze an HA control plane, use release/prod, and disable fleet"
unset CSOC_PROFILE MAGNUM_CLUSTER_NAME MAGNUM_STATE_FILE MAGNUM_KUBECONFIG_DIR \
  MAGNUM_MASTER_COUNT MAGNUM_MASTER_FLAVOR MAGNUM_NODE_COUNT MAGNUM_WORKER_FLAVOR \
  MAGNUM_MIN_NODE_COUNT MAGNUM_MAX_NODE_COUNT MAGNUM_EXPECTED_INITIAL_NODES
[[ ! -e "${REPO_ROOT}/argocd/apps/csoc-baseline.yaml" \
   && ! -d "${REPO_ROOT}/argocd/applicationsets" ]] \
  || log::die "Baseline Applications and ApplicationSets must be removed"
[[ $(yq -r '.applicationSet.replicas' "${REPO_ROOT}/iac/argocd/values.yaml") == 0 ]] \
  || log::die "The unused Argo ApplicationSet controller must remain disabled"
for kind in SpokeCluster SpokeEnvironmentConfig SpokeNetworkImportConfig \
  SpokeSharedNetworkConfig \
  AutoAllocatedSpokeNetwork DedicatedSpokeNetwork ImportedSpokeNetwork \
  IsolatedOpenStackNetwork RoutedSpokeNetwork FullyManagedSpokeNetwork \
  SharedProviderNetwork SpokeServerGroup SpokeSecurityGroup SpokeVolume; do
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
yq -e '.spec.namespaceResourceWhitelist[] | select(.group == "apps.csoc.js2.org" and .kind == "HelloApp")' \
  "${REPO_ROOT}/argocd/projects/csoc-baseline.yaml" >/dev/null \
  || log::die "CSOC baseline project does not permit trusted HelloApp instances"
[[ $(yq -r '.spec.destinations | map(.namespace) | join(",")' \
     "${REPO_ROOT}/argocd/projects/csoc-baseline.yaml") == kro-system ]] \
  || log::die "CSOC baseline project must not target spokeclusters namespaces"
[[ $(yq -r '.spec.orphanedResources.warn' "${REPO_ROOT}/argocd/projects/csoc-fleet.yaml") == true ]] \
  || log::die "Fleet project must warn about Git-retired resources awaiting deliberate teardown"
[[ $(yq -r '.spec.syncPolicy.automated.prune' "${REPO_ROOT}/argocd/apps/fleet.yaml") == false ]] \
  || log::die "Fleet pruning must remain disabled"

log::step 3 "Validating identity and network RGD restrictions"
RGD_PACKAGE_ROOT="${CATALOG_ROOT}/rgds/test-poc"
IDENTITY_RGD="${RGD_PACKAGE_ROOT}/cluster/v1/spoke-identity.rgd.yaml"
CONFIG_RGD="${RGD_PACKAGE_ROOT}/configmaps/immutable-spoke-config.rgd.yaml"
ENV_CONFIG_RGD="${RGD_PACKAGE_ROOT}/configmaps/spoke-environment-config.rgd.yaml"
IMPORT_CONFIG_RGD="${RGD_PACKAGE_ROOT}/configmaps/spoke-network-import-config.rgd.yaml"
AUTO_NETWORK_RGD="${RGD_PACKAGE_ROOT}/network/auto-allocated-spoke-network.rgd.yaml"
DEDICATED_NETWORK_RGD="${RGD_PACKAGE_ROOT}/network/dedicated-spoke-network.rgd.yaml"
IMPORTED_NETWORK_RGD="${RGD_PACKAGE_ROOT}/network/imported-spoke-network.rgd.yaml"
ISOLATED_NETWORK_RGD="${RGD_PACKAGE_ROOT}/network/isolated-openstack-network.rgd.yaml"
ROUTED_NETWORK_RGD="${RGD_PACKAGE_ROOT}/network/routed-spoke-network.rgd.yaml"
SERVER_GROUP_RGD="${RGD_PACKAGE_ROOT}/compute/spoke-server-group.rgd.yaml"
SECURITY_GROUP_RGD="${RGD_PACKAGE_ROOT}/security/spoke-security-group.rgd.yaml"
VOLUME_RGD="${RGD_PACKAGE_ROOT}/storage/spoke-volume.rgd.yaml"
SPOKE_RGD="${RGD_PACKAGE_ROOT}/cluster/v1/spoke-cluster.rgd.yaml"
HELLO_RGD="${RGD_PACKAGE_ROOT}/workloads/hello-app.rgd.yaml"
for rgd in "${CONFIG_RGD}" "${ENV_CONFIG_RGD}" "${IMPORT_CONFIG_RGD}" \
  "${IDENTITY_RGD}" "${AUTO_NETWORK_RGD}" "${DEDICATED_NETWORK_RGD}" \
  "${IMPORTED_NETWORK_RGD}" "${ISOLATED_NETWORK_RGD}" "${ROUTED_NETWORK_RGD}" \
  "${SERVER_GROUP_RGD}" "${SECURITY_GROUP_RGD}" "${VOLUME_RGD}" \
  "${SPOKE_RGD}" "${HELLO_RGD}"; do
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
for config_id in accountconfig computeconfig networkserviceconfig storageconfig \
  loadbalancerconfig kubernetesconfig; do
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
for config_id in accountconfig computeconfig networkserviceconfig storageconfig \
  loadbalancerconfig kubernetesconfig; do
  [[ $(yq -r ".spec.resources[] | select(.id == \"${config_id}\") | .template.immutable" "${IDENTITY_RGD}") == true ]] \
    || log::die "SpokeIdentity output ${config_id} must be immutable"
done
for config_id in networkconfig clusterconfig; do
  [[ $(yq -r ".spec.resources[] | select(.id == \"${config_id}\") | .template.immutable" "${ENV_CONFIG_RGD}") == true ]] \
    || log::die "SpokeEnvironmentConfig output ${config_id} must be immutable"
done
[[ $(yq -r '.spec.schema.spec | keys | join(",")' "${CONFIG_RGD}") \
   == projectID,compute,network,storage,loadBalancer,kubernetes ]] \
  || log::die "ImmutableSpokeConfig must expose separate service configuration groups"
[[ $(yq -r '.spec.schema.spec.compute | keys | join(",")' "${CONFIG_RGD}") \
   == imageID,sshKeyName,controlPlaneFlavor,generalWorkerFlavor,serverGroupPolicy ]] \
  || log::die "Immutable compute config must contain one approved general worker flavor"
[[ $(yq -r '.spec.schema.spec.kubernetes | keys | join(",")' "${CONFIG_RGD}") \
   == version,controlPlaneCount ]] \
  || log::die "Immutable Kubernetes config must contain only version and control-plane count"
[[ $(yq -r '.spec.resources[] | select(.id == "kubernetesconfig") | .template.data | keys | join(",")' "${CONFIG_RGD}") \
   == version,controlPlaneCount ]] \
  || log::die "Generated Kubernetes ConfigMap contains mutable bounds or unsupported worker classes"
[[ $(yq -r '.spec.schema.spec | keys | join(",")' "${ENV_CONFIG_RGD}") \
   == environment,nodeCIDR,podCIDR,serviceCIDR,networkMTU,enableDHCP,portSecurityEnabled ]] \
  || log::die "SpokeEnvironmentConfig must not expose a worker class"
[[ $(yq -r '.spec.resources[] | select(.id == "accountpolicy") | .template.spec.paramKind.kind' "${IDENTITY_RGD}") == SpokeIdentity ]] \
  || log::die "Account restrictions must be parameterized by SpokeIdentity"
for network_rgd in "${AUTO_NETWORK_RGD}" "${DEDICATED_NETWORK_RGD}" \
  "${IMPORTED_NETWORK_RGD}" "${ISOLATED_NETWORK_RGD}" "${ROUTED_NETWORK_RGD}"; do
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
for network_rgd in "${AUTO_NETWORK_RGD}" "${DEDICATED_NETWORK_RGD}" \
  "${IMPORTED_NETWORK_RGD}" "${ISOLATED_NETWORK_RGD}" "${ROUTED_NETWORK_RGD}"; do
  [[ $(yq -r '.spec.resources[] | select(.id == "connection") | .template.immutable' "${network_rgd}") == true ]] \
    || log::die "Network graph must emit an immutable connection ConfigMap"
done
for resource_id in network subnet router; do
  [[ $(yq -r ".spec.resources[] | select(.id == \"${resource_id}\") | .template.spec.managementPolicy" "${IMPORTED_NETWORK_RGD}") == unmanaged ]] \
    || log::die "Exact-ID imported ${resource_id} must be unmanaged"
  [[ $(yq -r ".spec.resources[] | select(.id == \"${resource_id}\") | .template.spec.import.id" "${IMPORTED_NETWORK_RGD}") \
     == '${importconfig.data.'"${resource_id}"'ID}' ]] \
    || log::die "Imported ${resource_id} must use its exact immutable ID"
done
for managed_rgd in "${ISOLATED_NETWORK_RGD}" "${ROUTED_NETWORK_RGD}"; do
  for resource_id in network subnet; do
    [[ $(yq -r ".spec.resources[] | select(.id == \"${resource_id}\") | .template.spec.managementPolicy" "${managed_rgd}") == managed \
       && $(yq -r ".spec.resources[] | select(.id == \"${resource_id}\") | .template.spec.managedOptions.onDelete" "${managed_rgd}") == delete ]] \
      || log::die "Managed network topology must use controller-owned deletion"
  done
done
[[ $(yq -r '.spec.resources[] | select(.id == "externalnetwork") | .template.spec.managementPolicy' "${ROUTED_NETWORK_RGD}") == unmanaged ]] \
  || log::die "Routed network must import its external network without ownership"
[[ $(yq -r '.spec.schema.spec | length' "${SERVER_GROUP_RGD}") == 0 \
   && $(yq -r '.spec.resources[] | select(.id == "servergroup") | .template.spec.resource.policy' "${SERVER_GROUP_RGD}") \
      == '${computeconfig.data.serverGroupPolicy}' ]] \
  || log::die "Server-group placement policy must come from immutable compute config"
[[ $(yq -r '.spec.schema.spec | keys | join(",")' "${VOLUME_RGD}") == sizeGB,description \
   && $(yq -r '.spec.resources[] | select(.id == "volume") | .template.spec.resource.volumeTypeRef' "${VOLUME_RGD}") \
      == '${volumetype.metadata.name}' ]] \
  || log::die "Volume type/AZ must come from immutable storage config"
[[ $(yq -r '.spec.resources[] | select(.id == "volumetype") | .template.spec.managementPolicy' "${VOLUME_RGD}") == unmanaged ]] \
  || log::die "Approved Cinder volume type must be imported without ownership"
yq -e '.spec.resources[] | select(.id == "securitygroup") | .template.spec.resource.rules[] | select(.direction == "ingress") | .portRange.min' \
  "${SECURITY_GROUP_RGD}" >/dev/null \
  || log::die "Security-group ingress must use the installed ORC rule schema"
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
for external_id in accountnamespace identity computeconfig networkserviceconfig storageconfig \
  loadbalancerconfig kubernetesconfig clusterconfig networkconnection; do
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
   == '${computeconfig.data.imageID}' ]] \
  || log::die "Approved image must come from the immutable compute ConfigMap"
[[ $(yq -r '.spec.resources[] | select(.id == "workermachinetemplate") | .template.spec.template.spec.flavor' "${SPOKE_RGD}") \
   == '${computeconfig.data.generalWorkerFlavor}' ]] \
  || log::die "Workers must use the immutable approved general flavor"
[[ $(yq -r '.spec.resources[] | select(.id == "cloudconfigresourceset") | .template.spec.resources[0].name' "${SPOKE_RGD}") \
   == '${identity.metadata.name + "-workload-cloud-config"}' ]] \
  || log::die "Workload credentials must be identity scoped"
[[ $(yq -r '.spec.resources[] | select(.id == "machinedeployment") | .template.spec.replicas // ""' "${SPOKE_RGD}") == "" ]] \
  || log::die "MachineDeployment replicas must remain under autoscaler ownership"
[[ $(yq -r '.spec.resources[] | select(.id == "openstackcluster") | .template.spec.managedSecurityGroups.allowAllInClusterTraffic' "${SPOKE_RGD}") == false ]] \
  || log::die "Spoke security groups must not allow all cluster traffic"

log::step 5 "Validating the development account and unified Hello delivery"
ACCOUNT_DIR="${FLEET_ROOT}/accounts/test-poc"
EXAMPLE_ACCOUNT_DIR="${FLEET_ROOT}/examples/accounts/test-poc"
CSOC_DIR="${FLEET_ROOT}/csoc"
[[ -f "${FLEET_ROOT}/kustomization.yaml" && -f "${CSOC_DIR}/kustomization.yaml" ]] \
  || log::die "Fleet root must expose its CSOC and account packages"
[[ -f "${FLEET_ROOT}/accounts/kustomization.yaml" && -f "${ACCOUNT_DIR}/kustomization.yaml" \
   && -f "${EXAMPLE_ACCOUNT_DIR}/kustomization.yaml" ]] \
  || log::die "Fleet must provide active development and inactive example packages"
[[ $(yq -r '.resources | join(",")' "${FLEET_ROOT}/accounts/kustomization.yaml") == test-poc ]] \
  || log::die "Development fleet must activate only test-poc"
while IFS= read -r active_manifest; do
  relative_manifest=${active_manifest#"${FLEET_ROOT}/"}
  git -C "${FLEET_ROOT}" ls-files --error-unmatch "${relative_manifest}" >/dev/null \
    || log::die "Active GitOps manifest is not tracked: ${relative_manifest}"
  if git -C "${FLEET_ROOT}" check-ignore -q "${relative_manifest}"; then
    log::die "Active GitOps manifest is ignored: ${relative_manifest}"
  fi
done < <(find "${ACCOUNT_DIR}" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
[[ $(yq -r '.kind + ":" + .metadata.name' "${CSOC_DIR}/hello-app.yaml") \
   == HelloApp:csoc ]] \
  || log::die "Fleet must contain the CSOC-local Hello instance"
mapfile -t hello_iac_files < <(
  {
    find "${RGD_PACKAGE_ROOT}/workloads" -maxdepth 1 -type f -name '*hello*.yaml' -printf 'rgds/test-poc/workloads/%f\n'
    find "${FLEET_ROOT}/csoc" -maxdepth 1 -type f -name '*hello*.yaml' -printf 'csoc/%f\n'
  } | sort
)
[[ "${hello_iac_files[*]}" == \
   "csoc/hello-app.yaml rgds/test-poc/workloads/hello-app.rgd.yaml" ]] \
  || log::die "Expected exactly one active Hello RGD and one active CSOC instance"
[[ $(yq -r '.kind + ":" + .metadata.name' "${ACCOUNT_DIR}/identity-config.yaml") \
   == ImmutableSpokeConfig:test-poc ]] \
  || log::die "The development account must include ImmutableSpokeConfig"
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
[[ "${min_nodes}:${max_nodes}" == 1:2 ]] \
  || log::die "Development test-poc must use 1..2 worker bounds"
[[ $(yq -r '.spec.compute.controlPlaneFlavor + ":" + .spec.compute.generalWorkerFlavor' \
     "${ACCOUNT_DIR}/identity-config.yaml") == m3.small:m3.quad ]] \
  || log::die "Development test-poc must use m3.small control plane and m3.quad workers"
[[ $(yq -r '.spec.network.apiServerAllowedCIDR' "${ACCOUNT_DIR}/identity-config.yaml") \
   == 149.165.155.5/32 ]] \
  || log::die "Development spoke API must be restricted to the reviewed CSOC router SNAT address"
[[ ! -e "${ACCOUNT_DIR}/network-dedicated.yaml" ]] \
  || log::die "Active accounts must expose the selected graph only as network.yaml"
[[ $(yq -r '.spec.kubernetes | keys | join(",")' "${ACCOUNT_DIR}/identity-config.yaml") \
   == version,controlPlaneCount ]] \
  || log::die "test-poc immutable config must not contain scale bounds or unsupported worker classes"
[[ $(yq -r '.spec | keys | join(",")' "${ACCOUNT_DIR}/cluster.yaml") == kubernetes \
   && $(yq -r '.spec.kubernetes | keys | join(",")' "${ACCOUNT_DIR}/cluster.yaml") == minNodes,maxNodes ]] \
  || log::die "test-poc SpokeCluster must contain only mutable worker bounds"
node_cidr=$(yq -er '.spec.nodeCIDR' "${ACCOUNT_DIR}/spoke-config.yaml")
[[ ${node_cidr} =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]] \
  || log::die "Dedicated network CIDR is not RFC1918"
if rg --line-number '(secret(Name|Ref)|applicationCredential|credentialSecret):' \
    "${FLEET_ROOT}/accounts" "${FLEET_ROOT}/examples"; then
  log::die "Fleet instances must not name or embed credentials"
fi
if rg --line-number 'SpokeCluster|cluster\.x-k8s\.io|infrastructure\.cluster\.x-k8s\.io' \
    "${REPO_ROOT}/scripts/bootstrap/magnum" "${REPO_ROOT}/scripts/operations/magnum"; then
  log::die "Magnum lifecycle must manage only the CSOC management cluster"
fi
rg -Fq '<body><h1>Hello ${schema.metadata.name}.</h1></body>' "${HELLO_RGD}" \
  || log::die "HelloApp must render the selected spoke name"
rg -q 'replicas: \$\{string\(schema\.spec\.replicas\)\}' "${HELLO_RGD}" \
  || log::die "HelloApp must stringify replicas inside its manifest payload"
rg -q 'service\.beta\.kubernetes\.io/openstack-internal-load-balancer: "true"' "${HELLO_RGD}" \
  || log::die "Spoke HelloApp must use an internal OpenStack load balancer"
rg -q 'type: LoadBalancer' "${HELLO_RGD}" \
  || log::die "Spoke HelloApp must create its own application load balancer"
[[ $(yq -r '.spec.schema.scope' "${HELLO_RGD}") == Namespaced ]] \
  || log::die "HelloApp must be an account-scoped workload graph"
[[ $(yq -r '.spec.schema.spec.target' "${HELLO_RGD}") == 'string | default="spoke" enum="csoc,spoke"' ]] \
  || log::die "HelloApp must explicitly select CSOC or spoke delivery"
yq -e '.spec.resources[] | select(.id == "resourceset") | .template.kind == "ClusterResourceSet"' \
  "${HELLO_RGD}" >/dev/null || log::die "HelloApp must deploy through CAPI ClusterResourceSet"
[[ $(yq -r '.spec.resources[] | select(.id == "csochtml") | .template.data."index.html"' "${HELLO_RGD}" \
    | rg -o 'Hello CSOC\.') == "Hello CSOC." ]] \
  || log::die "CSOC Hello message is incorrect"
[[ $(yq -r '.spec.resources[] | select(.id == "csocservice") | .template.spec.type' "${HELLO_RGD}") \
   == LoadBalancer ]] \
  || log::die "CSOC Hello must create its own application load balancer"
[[ $(yq -r '.spec.resources[] | select(.id == "csocservice") | .template.metadata.annotations."service.beta.kubernetes.io/openstack-internal-load-balancer"' "${HELLO_RGD}") \
   == true ]] \
  || log::die "CSOC Hello load balancer must remain internal"
if rg --line-number 'floating-network-id|loadBalancerIP|0\.0\.0\.0/0' \
    "${RGD_PACKAGE_ROOT}/workloads" "${FLEET_ROOT}/csoc" "${ACCOUNT_DIR}/hello-app.yaml"; then
  log::die "Hello workloads must not request a public or unrestricted address"
fi

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
  --values "${REPO_ROOT}/iac/argocd/values.yaml" \
  --post-renderer "${REPO_ROOT}/scripts/bootstrap/argocd/filter-applicationset-controller.sh" \
  >"${render_dir}/argocd.yaml"
if [[ -n $(yq -r 'select(.metadata.name == "argocd-applicationset-controller") | .kind' \
    "${render_dir}/argocd.yaml") ]]; then
  log::die "Post-rendered Argo manifests contain the unused ApplicationSet controller"
fi
helm template cert-manager cert-manager --repo https://charts.jetstack.io \
  --version "v${CERT_MANAGER_VERSION}" --namespace cert-manager --set crds.enabled=true >/dev/null
helm template kro oci://registry.k8s.io/kro/charts/kro \
  --version "${KRO_VERSION}" --namespace kro-system >/dev/null

log::step 7 "Running local lifecycle and credential regression tests"
bash "${REPO_ROOT}/tests/magnum/run.sh"
bash "${REPO_ROOT}/tests/credentials/run.sh"
bash "${REPO_ROOT}/tests/spokes/run.sh"

log::success "All modular KRO non-destructive validation checks passed."
