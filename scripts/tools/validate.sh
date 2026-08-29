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
bash "${REPO_ROOT}/scripts/tools/validate-clusters.sh"

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
for profile_manifest in iac/csoc/profiles/dev.profile iac/csoc/profiles/staging.profile \
  iac/csoc/profiles/prod.profile; do
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
for root_manifest in "${REPO_ROOT}"/iac/csoc/profiles/*-app-of-apps.yaml; do
  [[ $(yq -r '.spec.project' "${root_manifest}") == rgds ]] \
    || log::die "App-of-Apps must belong to rgds: ${root_manifest}"
done
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
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
for profile in dev staging prod; do
  (
    unset CSOC_PROFILE_NAME CSOC_FLEET_ENABLED CSOC_BOOTSTRAP_REVISION
    unset CSOC_CATALOG_REVISION CSOC_FLEET_REVISION CSOC_ARGO_ROOT_MANIFEST_REL
    unset CSOC_APPLICATION_DIR_REL CSOC_FLEET_PATH MAGNUM_CLUSTER_NAME
    unset MAGNUM_STATE_FILE MAGNUM_KUBECONFIG_DIR MAGNUM_MASTER_COUNT
    unset MAGNUM_MASTER_FLAVOR MAGNUM_NODE_COUNT MAGNUM_WORKER_FLAVOR
    unset MAGNUM_MIN_NODE_COUNT MAGNUM_MAX_NODE_COUNT MAGNUM_EXPECTED_INITIAL_NODES
    unset MAGNUM_BOOT_VOLUME_SIZE MAGNUM_AUTO_SCALING_ENABLED
    CSOC_PROFILE=${profile}
    csoc::load_profile "${REPO_ROOT}"
    expected_revision="environment/${profile}"
    [[ "${MAGNUM_CLUSTER_NAME}" == "js-csoc-${profile}" \
       && "${CSOC_BOOTSTRAP_REVISION}" == "${expected_revision}" \
       && "${CSOC_CATALOG_REVISION}" == "${expected_revision}" \
       && "${CSOC_FLEET_REVISION}" == "${expected_revision}" ]] \
      || log::die "${profile} profile identity or revisions are inconsistent"
    app_dir="${REPO_ROOT}/${CSOC_APPLICATION_DIR_REL}"
    [[ -f "${app_dir}/controllers.yaml" && -f "${app_dir}/rgds.yaml" ]] \
      || log::die "${profile} controller/RGD Applications are missing"
    [[ $(yq -r '.spec.source.targetRevision' "${app_dir}/controllers.yaml") == "${expected_revision}" \
       && $(yq -r '.spec.source.targetRevision' "${app_dir}/rgds.yaml") == "${expected_revision}" \
       && $(yq -r '.spec.source.repoURL' "${app_dir}/rgds.yaml") \
          == https://github.com/jayadeyemi/js-poc-csoc-app-catalog ]] \
      || log::die "${profile} Applications do not use coordinated revisions"
    if [[ "${CSOC_FLEET_ENABLED}" == true ]]; then
      [[ -f "${app_dir}/fleet.yaml" \
         && $(yq -r '.spec.source.targetRevision' "${app_dir}/fleet.yaml") == "${expected_revision}" \
         && $(yq -r '.spec.source.path' "${app_dir}/fleet.yaml") == "accounts/${profile}" ]] \
        || log::die "${profile} fleet Application is inconsistent"
    else
      [[ ! -e "${app_dir}/fleet.yaml" ]] \
        || log::die "${profile} must not declare a fleet Application"
    fi
  )
done
[[ $(CSOC_PROFILE=dev bash -c 'source "$1"; csoc::load_profile "$2"; printf "%s:%s:%s" "$MAGNUM_BOOT_VOLUME_SIZE" "$MAGNUM_MASTER_FLAVOR" "$CSOC_FLEET_ENABLED"' _ "${REPO_ROOT}/scripts/lib/csoc-profile.bash" "${REPO_ROOT}") == 20:m3.quad:false ]] \
  || log::die "Dev must use the quad no-fleet profile"
[[ $(CSOC_PROFILE=staging bash -c 'source "$1"; csoc::load_profile "$2"; printf "%s:%s" "$MAGNUM_BOOT_VOLUME_SIZE" "$CSOC_FLEET_ENABLED"' _ "${REPO_ROOT}/scripts/lib/csoc-profile.bash" "${REPO_ROOT}") == 20:true ]] \
  || log::die "Staging sizing or fleet policy is incorrect"
[[ $(CSOC_PROFILE=prod bash -c 'source "$1"; csoc::load_profile "$2"; printf "%s:%s:%s" "$MAGNUM_BOOT_VOLUME_SIZE" "$MAGNUM_MASTER_COUNT" "$CSOC_FLEET_ENABLED"' _ "${REPO_ROOT}/scripts/lib/csoc-profile.bash" "${REPO_ROOT}") == 20:3:true ]] \
  || log::die "Prod sizing or fleet policy is incorrect"
[[ ! -e "${REPO_ROOT}/argocd/apps/csoc-baseline.yaml" \
   && ! -d "${REPO_ROOT}/argocd/applicationsets" ]] \
  || log::die "Baseline Applications and ApplicationSets must be removed"
[[ $(yq -r '.applicationSet.replicas' "${REPO_ROOT}/iac/argocd/values.yaml") == 0 ]] \
  || log::die "The unused Argo ApplicationSet controller must remain disabled"
for kind in SpokeCluster SpokeEnvironmentConfig SpokeNetworkImportConfig \
  SpokeSharedNetworkConfig \
  AutoAllocatedSpokeNetwork DedicatedSpokeNetwork ImportedSpokeNetwork \
  IsolatedOpenStackNetwork RoutedSpokeNetwork FullyManagedSpokeNetwork \
  SharedProviderNetwork SpokeKeypair SpokeServerGroup SpokeSecurityGroup SpokeVolume; do
  yq -e ".spec.namespaceResourceWhitelist[] | select(.group == \"csoc.js2.org\" and .kind == \"${kind}\")" \
    "${REPO_ROOT}/argocd/projects/csoc-fleet.yaml" >/dev/null \
    || log::die "Fleet project does not permit ${kind}"
done
for kind in ImmutableSpokeConfig SpokeIdentity; do
  yq -e ".spec.clusterResourceWhitelist[] | select(.group == \"csoc.js2.org\" and .kind == \"${kind}\")" \
    "${REPO_ROOT}/argocd/projects/csoc-fleet.yaml" >/dev/null \
    || log::die "Fleet project does not permit cluster-scoped ${kind}"
done
for kind in HelloApp SpokeHelloApp SpokeGitOps SpokeArgoCD SpokeArgoApplication; do
  yq -e ".spec.namespaceResourceWhitelist[] | select(.group == \"apps.csoc.js2.org\" and .kind == \"${kind}\")" \
    "${REPO_ROOT}/argocd/projects/csoc-fleet.yaml" >/dev/null \
    || log::die "Fleet project does not permit ${kind}"
done
yq -e '.spec.namespaceResourceWhitelist[] | select(.group == "apps.csoc.js2.org" and .kind == "HelloApp")' \
  "${REPO_ROOT}/argocd/projects/csoc-baseline.yaml" >/dev/null \
  || log::die "CSOC baseline project does not permit trusted HelloApp instances"
[[ $(yq -r '.spec.destinations | map(.namespace) | join(",")' \
     "${REPO_ROOT}/argocd/projects/csoc-baseline.yaml") == kro-system ]] \
  || log::die "CSOC baseline project must not target spokeclusters namespaces"
[[ $(yq -r '.spec.orphanedResources.warn' "${REPO_ROOT}/argocd/projects/csoc-fleet.yaml") == true ]] \
  || log::die "Fleet project must warn about Git-retired resources awaiting deliberate teardown"
for fleet_app in "${REPO_ROOT}"/argocd/environments/{staging,prod}/apps/fleet.yaml; do
  [[ $(yq -r '.spec.syncPolicy.automated.prune' "${fleet_app}") == false ]] \
    || log::die "Fleet pruning must remain disabled: ${fleet_app}"
done

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
KEYPAIR_RGD="${RGD_PACKAGE_ROOT}/compute/spoke-keypair.rgd.yaml"
SECURITY_GROUP_RGD="${RGD_PACKAGE_ROOT}/security/spoke-security-group.rgd.yaml"
VOLUME_RGD="${RGD_PACKAGE_ROOT}/storage/spoke-volume.rgd.yaml"
SPOKE_RGD="${RGD_PACKAGE_ROOT}/cluster/v1/spoke-cluster.rgd.yaml"
HELLO_RGD="${RGD_PACKAGE_ROOT}/workloads/hello-app.rgd.yaml"
SPOKE_HELLO_RGD="${RGD_PACKAGE_ROOT}/workloads/spoke-hello-app.rgd.yaml"
SPOKE_GITOPS_RGD="${RGD_PACKAGE_ROOT}/workloads/spoke-gitops.rgd.yaml"
SPOKE_ARGOCD_RGD="${RGD_PACKAGE_ROOT}/workloads/spoke-argocd.rgd.yaml"
SPOKE_ARGO_APPLICATION_RGD="${RGD_PACKAGE_ROOT}/workloads/spoke-argo-application.rgd.yaml"
for rgd in "${CONFIG_RGD}" "${ENV_CONFIG_RGD}" "${IMPORT_CONFIG_RGD}" \
  "${IDENTITY_RGD}" "${AUTO_NETWORK_RGD}" "${DEDICATED_NETWORK_RGD}" \
  "${IMPORTED_NETWORK_RGD}" "${ISOLATED_NETWORK_RGD}" "${ROUTED_NETWORK_RGD}" \
  "${KEYPAIR_RGD}" "${SERVER_GROUP_RGD}" "${SECURITY_GROUP_RGD}" "${VOLUME_RGD}" \
  "${SPOKE_RGD}" "${HELLO_RGD}" "${SPOKE_HELLO_RGD}" "${SPOKE_GITOPS_RGD}" \
  "${SPOKE_ARGOCD_RGD}" "${SPOKE_ARGO_APPLICATION_RGD}"; do
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
for secret_id in cloudconfigsecret workloadcloudconfigsecret; do
  [[ $(yq -r ".spec.resources[] | select(.id == \"${secret_id}\") | .externalRef.kind" "${IDENTITY_RGD}") == Secret ]] \
    || log::die "SpokeIdentity must require runtime credential Secret ${secret_id}"
done
rg -Fq 'cloudconfigsecret.metadata.name != "" && workloadcloudconfigsecret.metadata.name != ""' "${IDENTITY_RGD}" \
  || log::die "SpokeIdentity readiness must include both credential Secrets"
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
   == imageID,sshPublicKey,controlPlaneFlavor,generalWorkerFlavor,serverGroupPolicy ]] \
  || log::die "Immutable compute config must contain one approved general worker flavor"
[[ $(yq -r '.spec.schema.spec.kubernetes | keys | join(",")' "${CONFIG_RGD}") \
   == version,controlPlaneCount ]] \
  || log::die "Immutable Kubernetes config must contain only version and control-plane count"
[[ $(yq -r '.spec.resources[] | select(.id == "kubernetesconfig") | .template.data | keys | join(",")' "${CONFIG_RGD}") \
   == version,controlPlaneCount ]] \
  || log::die "Generated Kubernetes ConfigMap contains mutable bounds or unsupported worker classes"
[[ $(yq -r '.spec.schema.spec.network | has("applicationAllowedCIDR")' "${CONFIG_RGD}") == false \
   && $(yq -r '.spec.resources[] | select(.id == "networkserviceconfig") | .template.data | has("applicationAllowedCIDR")' "${CONFIG_RGD}") == false ]] \
  || log::die "Mutable application access policy must not enter immutable network configuration"
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
[[ $(yq -r '.spec.schema.spec | length' "${KEYPAIR_RGD}") == 0 \
   && $(yq -r '.spec.resources[] | select(.id == "keypair") | .template.kind' "${KEYPAIR_RGD}") == KeyPair \
   && $(yq -r '.spec.resources[] | select(.id == "keypair") | .template.spec.managementPolicy' "${KEYPAIR_RGD}") == managed \
   && $(yq -r '.spec.resources[] | select(.id == "keypair") | .template.spec.managedOptions.onDelete' "${KEYPAIR_RGD}") == delete \
   && $(yq -r '.spec.resources[] | select(.id == "keypair") | .template.spec.resource.publicKey' "${KEYPAIR_RGD}") == '${computeconfig.data.sshPublicKey}' \
   && $(yq -r '.spec.resources[] | select(.id == "connection") | .template.immutable' "${KEYPAIR_RGD}") == true ]] \
  || log::die "SpokeKeypair must create and delete an ORC keypair from immutable public-key config"
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
  loadbalancerconfig kubernetesconfig clusterconfig networkconnection keypairconnection; do
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
for template_id in controlplanemachinetemplate workermachinetemplate; do
  [[ $(yq -r ".spec.resources[] | select(.id == \"${template_id}\") | .template.spec.template.spec.sshKeyName" "${SPOKE_RGD}") \
     == '${keypairconnection.data.keypairName}' ]] \
    || log::die "${template_id} must consume the ORC-managed keypair connection"
  [[ $(yq -r ".spec.resources[] | select(.id == \"${template_id}\") | .template.spec.template.spec.rootVolume.sizeGiB" "${SPOKE_RGD}") == 20 \
     && $(yq -r ".spec.resources[] | select(.id == \"${template_id}\") | .template.spec.template.spec.rootVolume.type" "${SPOKE_RGD}") == '${storageconfig.data.volumeType}' \
     && $(yq -r ".spec.resources[] | select(.id == \"${template_id}\") | .template.spec.template.spec.rootVolume.availabilityZone.name" "${SPOKE_RGD}") == '${storageconfig.data.availabilityZone}' ]] \
    || log::die "${template_id} must use an immutable 20-GiB Cinder root volume"
done
[[ $(yq -r '.spec.resources[] | select(.id == "cloudconfigresourceset") | .template.spec.resources[0].name' "${SPOKE_RGD}") \
   == '${identity.metadata.name + "-workload-cloud-config"}' ]] \
  || log::die "Workload credentials must be identity scoped"
rg -Fq 'cloudconfigresourceset.?status.?conditions' "${SPOKE_RGD}" \
  || log::die "SpokeCluster readiness must include workload cloud-config delivery"
[[ $(yq -r '.spec.resources[] | select(.id == "machinedeployment") | .template.spec.replicas // ""' "${SPOKE_RGD}") == "" ]] \
  || log::die "MachineDeployment replicas must remain under autoscaler ownership"
[[ $(yq -r '.spec.resources[] | select(.id == "openstackcluster") | .template.spec.managedSecurityGroups.allowAllInClusterTraffic' "${SPOKE_RGD}") == false ]] \
  || log::die "Spoke security groups must not allow all cluster traffic"

log::step 5 "Validating environment ownership and direct spoke workloads"
EXAMPLES_DIR="${FLEET_ROOT}/examples"
[[ -f "${FLEET_ROOT}/kustomization.yaml" && -f "${FLEET_ROOT}/ownership.yaml" \
   && -f "${EXAMPLES_DIR}/README.md" ]] \
  || log::die "Fleet root must expose ownership and documented examples"
[[ $(yq -r '.resources | length' "${FLEET_ROOT}/kustomization.yaml") == 0 \
   && $(yq -r '.resources | length' "${FLEET_ROOT}/accounts/dev/kustomization.yaml") == 0 ]] \
  || log::die "Fleet root and dev owner root must never render instances"
declare -A ownership_keys=()
while IFS='|' read -r account app environment owner path; do
  key="${account}/${app}/${environment}"
  [[ -n "${account}" && -n "${app}" && -n "${environment}" && -n "${owner}" && -n "${path}" ]] \
    || log::die "Fleet ownership entry has an empty field"
  [[ -z "${ownership_keys[${key}]:-}" ]] \
    || log::die "Fleet tuple ${key} has more than one owner"
  ownership_keys[${key}]="${owner}"
  expected_path="accounts/${owner}/accounts/${account}/${app}/${environment}"
  [[ "${path}" == "${expected_path}" && -d "${FLEET_ROOT}/${path}" ]] \
    || log::die "Fleet tuple ${key} path does not match owner ${owner}"
  canonical_name="${account}-${app}-${environment}"
  for manifest in identity-config identity spoke-config network keypair cluster; do
    [[ -f "${FLEET_ROOT}/${path}/${manifest}.yaml" ]] \
      || log::die "Fleet tuple ${key} is missing ${manifest}.yaml"
  done
  [[ $(yq -r '.metadata.name' "${FLEET_ROOT}/${path}/identity-config.yaml") == "${canonical_name}" \
     && $(yq -r '.metadata.labels."csoc.js2.org/account"' "${FLEET_ROOT}/${path}/identity-config.yaml") == "${account}" \
     && $(yq -r '.metadata.labels."csoc.js2.org/app"' "${FLEET_ROOT}/${path}/identity-config.yaml") == "${app}" \
     && $(yq -r '.metadata.labels."csoc.js2.org/environment"' "${FLEET_ROOT}/${path}/identity-config.yaml") == "${environment}" \
     && $(yq -r '.metadata.name' "${FLEET_ROOT}/${path}/identity.yaml") == "${canonical_name}" \
     && $(yq -r '.metadata.name' "${FLEET_ROOT}/${path}/cluster.yaml") == "${canonical_name}" \
     && $(yq -r '.metadata.namespace' "${FLEET_ROOT}/${path}/cluster.yaml") == "spokeclusters-${canonical_name}" ]] \
    || log::die "Fleet tuple ${key} does not use its canonical name/namespace"
  if [[ -f "${FLEET_ROOT}/${path}/hello-app.yaml" ]]; then
    [[ ! -e "${FLEET_ROOT}/${path}/argocd.yaml" \
       && ! -e "${FLEET_ROOT}/${path}/application.yaml" \
       && $(yq -r '.spec.clusterName' "${FLEET_ROOT}/${path}/hello-app.yaml") == "${canonical_name}" ]] \
      || log::die "Fleet tuple ${key} mixes central and spoke-local workload ownership"
  else
    [[ -f "${FLEET_ROOT}/${path}/argocd.yaml" \
       && -f "${FLEET_ROOT}/${path}/application.yaml" \
       && $(yq -r '.spec.clusterName' "${FLEET_ROOT}/${path}/argocd.yaml") == "${canonical_name}" \
       && $(yq -r '.spec.clusterName' "${FLEET_ROOT}/${path}/application.yaml") == "${canonical_name}" \
       && $(yq -r '.spec.argoCDName' "${FLEET_ROOT}/${path}/application.yaml") == "${canonical_name}" ]] \
      || log::die "Fleet tuple ${key} lacks a complete modular spoke-local Argo owner"
    expected_application_path="argo/accounts/${owner}/accounts/${account}/${app}/${environment}"
    [[ $(yq -r '.spec.repositoryURL' "${FLEET_ROOT}/${path}/application.yaml") == https://github.com/jayadeyemi/gitops.git \
       && $(yq -r '.spec.targetRevision' "${FLEET_ROOT}/${path}/application.yaml") =~ ^[0-9a-f]{40}$ \
       && $(yq -r '.spec.path' "${FLEET_ROOT}/${path}/application.yaml") == "${expected_application_path}" ]] \
      || log::die "Fleet tuple ${key} must pin its ordered GitOps application path"
  fi
done < <(yq -r '.assignments[] | [.account,.app,.environment,.owner,.path] | join("|")' \
  "${FLEET_ROOT}/ownership.yaml")
[[ "${ownership_keys[test-poc/hello-app/dev]:-}" == staging ]] \
  || log::die "test-poc/hello-app/dev must be staging-owned"
[[ "${ownership_keys[training-account/jupyterhub/dev]:-}" == staging ]] \
  || log::die "training-account/jupyterhub/dev must be staging-owned"
[[ "${ownership_keys[training-account/registry-cache/dev]:-}" == staging ]] \
  || log::die "training-account/registry-cache/dev must be staging-owned"
[[ "${ownership_keys[training-account/monitoring/dev]:-}" == staging ]] \
  || log::die "training-account/monitoring/dev must be staging-owned"
[[ -f "${EXAMPLES_DIR}/retired/poc-tenant-dev/kustomization.yaml" ]] \
  || log::die "Retired poc-tenant-dev composition must remain documented"
(( $(find "${EXAMPLES_DIR}/compositions" -mindepth 1 -maxdepth 1 -type d | wc -l) >= 5 )) \
  || log::die "Fleet must include multiple complete composition examples"
while IFS= read -r kustomization; do
  [[ -f "$(dirname "${kustomization}")/README.md" ]] \
    || log::die "Example package lacks README: ${kustomization}"
done < <(find "${EXAMPLES_DIR}/compositions" "${EXAMPLES_DIR}/connections" -name kustomization.yaml | sort)
[[ $(yq -r '.spec.resources[] | select(.id == "service") | .template.metadata.annotations."service.beta.kubernetes.io/openstack-internal-load-balancer"' "${HELLO_RGD}") == true ]] \
  || log::die "CSOC Hello load balancer must remain internal"
yq -e '.spec.resources[] | select(.id == "resourceset") | .template.kind == "ClusterResourceSet"' \
  "${SPOKE_HELLO_RGD}" >/dev/null || log::die "SpokeHelloApp must use CAPI ClusterResourceSet"
HELLO_SPOKE_PAYLOAD=$(yq -r '.spec.resources[] | select(.id == "workload") | .template.data."hello-app.yaml"' "${SPOKE_HELLO_RGD}")
for expected_hello_setting in \
  'loadbalancer.openstack.org/floating-network-id: ${networkconnection.data.externalNetworkID}' \
  'loadBalancerSourceRanges:' '- ${schema.spec.applicationAllowedCIDR}'; do
  rg -Fq -- "${expected_hello_setting}" <<<"${HELLO_SPOKE_PAYLOAD}" \
    || log::die "SpokeHelloApp is missing: ${expected_hello_setting}"
done
[[ $(yq -r '.spec.resources[] | select(.id == "argocd") | .template.kind' "${SPOKE_GITOPS_RGD}") == HelmChartProxy \
   && $(yq -r '.spec.resources[] | select(.id == "argocd") | .template.spec.version' "${SPOKE_GITOPS_RGD}") == "${ARGOCD_CHART_VERSION}" ]] \
  || log::die "SpokeGitOps must install the pinned Argo CD chart through CAPI addons"
rg -Fq 'repoURL: ${schema.spec.repositoryURL}' "${SPOKE_GITOPS_RGD}" \
  || log::die "SpokeGitOps root Application must use the declared repository"
[[ $(yq -r '.spec.resources[] | select(.id == "argocd") | .template.kind' "${SPOKE_ARGOCD_RGD}") == HelmChartProxy \
   && $(yq -r '.spec.resources[] | select(.id == "argocd") | .template.spec.version' "${SPOKE_ARGOCD_RGD}") == "${ARGOCD_CHART_VERSION}" ]] \
  || log::die "SpokeArgoCD must own only the pinned Argo CD HelmChartProxy"
[[ $(yq -r '.spec.schema.spec.targetRevision' "${SPOKE_ARGO_APPLICATION_RGD}") == *'^[0-9a-f]{40}$'* \
   && $(yq -r '.spec.resources[] | select(.id == "resourceset") | .template.spec.strategy' "${SPOKE_ARGO_APPLICATION_RGD}") == Reconcile ]] \
  || log::die "SpokeArgoApplication must require an immutable revision and reconcile continuously"
while IFS= read -r rgd; do
  [[ -f "${rgd%.yaml}.md" ]] || log::die "RGD lacks paired documentation: ${rgd}"
done < <(find "${RGD_PACKAGE_ROOT}" -type f -name '*.rgd.yaml' | sort)
if rg --line-number '(secret(Name|Ref)|applicationCredential|credentialSecret):' \
    "${FLEET_ROOT}/accounts" "${FLEET_ROOT}/examples"; then
  log::die "Fleet instances must not name or embed credentials"
fi
if rg --line-number 'loadBalancerIP|0\.0\.0\.0/0' \
    "${RGD_PACKAGE_ROOT}/workloads" "${FLEET_ROOT}/accounts" "${EXAMPLES_DIR}"; then
  log::die "Hello workloads must not request an unrestricted address"
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
