#!/usr/bin/env bash
# Static second-generation API, ownership, controller, and delivery gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
CATALOG_ROOT="${WORKSPACE_ROOT}/js-poc-csoc-app-catalog"
FLEET_ROOT="${WORKSPACE_ROOT}/js-poc-csoc-fleet"
CONFIG_ROOT="${WORKSPACE_ROOT}/../references/config"
GITOPS_ROOT="${WORKSPACE_ROOT}/../references/gitops"
V2_ROOT="${CATALOG_ROOT}/rgds/v2"

source "${REPO_ROOT}/versions.env"

for command_name in jq kubectl rg sh yq; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "missing ${command_name}" >&2; exit 1; }
done

mapfile -d '' -t v2_yaml_files < <(find "${V2_ROOT}" -type f -name '*.yaml' ! -name kustomization.yaml -print0 | sort -z)
[[ ${#v2_yaml_files[@]} -gt 0 ]] || { echo "no v2 RGD manifests found" >&2; exit 1; }

for yaml_file in "${v2_yaml_files[@]}" "${REPO_ROOT}/controllers/registration.yaml"; do
  yq eval '.' "${yaml_file}" >/dev/null
done
for yaml_file in "${v2_yaml_files[@]}"; do
  [[ $(yq eval-all 'documentIndex' "${yaml_file}" | rg -v '^---$' | wc -l) == 1 ]] \
    || { echo "v2 RGD manifest must contain exactly one document: ${yaml_file}" >&2; exit 1; }
done
kubectl kustomize "${CATALOG_ROOT}/rgds" >/dev/null
kubectl kustomize "${CATALOG_ROOT}/rgds/v2" >/dev/null
declare -A expected_waves=(
  [SpokeAccount]=-12 [MachineProfile]=-11 [SpokeNetwork]=-11 [WorkloadCluster]=-10
  [SpokeNodePool]=-9 [SpokeRegistration]=-9 [ClusterFoundation]=-8 [ApplicationBoundary]=-8
  [CephFSAddon]=-7 [GpuRuntimeAddon]=-7 [S3CSIAddon]=-7
  [EndpointBinding]=-6 [HubAuthBinding]=-6 [SecretBundle]=-6 [CinderStorageBinding]=-6
  [CephFSVolumeBinding]=-6 [S3VolumeBinding]=-6
  [SmokeApplication]=-5 [JupyterHubInstance]=-5 [MonitoringInstance]=-5
  [RegistryCacheInstance]=-5 [BinderBuildInstance]=-5 [JupyterOutpostInstance]=-5
)
for yaml_file in "${v2_yaml_files[@]}"; do
  kind=$(yq -r '.spec.schema.kind' "${yaml_file}")
  wave=$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave"' "${yaml_file}")
  [[ "${wave}" == "${expected_waves[${kind}]}" ]] \
    || { echo "unexpected RGD compile wave for ${kind}: ${wave}" >&2; exit 1; }
done

mapfile -t kinds < <(yq eval-all '.spec.schema.kind' "${v2_yaml_files[@]}" | rg -v '^---$' | sort -u)
expected_kinds=(ApplicationBoundary BinderBuildInstance CephFSAddon CephFSVolumeBinding CinderStorageBinding ClusterFoundation EndpointBinding GpuRuntimeAddon HubAuthBinding JupyterHubInstance JupyterOutpostInstance MachineProfile MonitoringInstance RegistryCacheInstance S3CSIAddon S3VolumeBinding SecretBundle SmokeApplication SpokeAccount SpokeNetwork SpokeNodePool SpokeRegistration WorkloadCluster)
[[ "${kinds[*]}" == "${expected_kinds[*]}" ]] || { echo "unexpected v2 Kind inventory: ${kinds[*]}" >&2; exit 1; }

[[ $(yq eval-all 'select(.spec.schema.group == "csoc.js2.org" or .spec.schema.group == "apps.csoc.js2.org") | .spec.schema.kind' "${v2_yaml_files[@]}" | rg -v '^---$' | wc -l) == 0 ]] \
  || { echo "v2 reused a compatibility API group" >&2; exit 1; }
[[ $(yq eval-all 'select(.spec.schema.kind == "MachineProfile") | [.spec.resources[] | select(.id == "image" or .id == "volumetype") | .template.spec.managementPolicy] | join(",")' "${V2_ROOT}/infrastructure/machineprofile.rgds.yaml") == unmanaged,unmanaged ]] \
  || { echo "MachineProfile UUID imports must remain unmanaged" >&2; exit 1; }
[[ $(yq '[.spec.resources[] | select(.template.kind == "Flavor")] | length' "${V2_ROOT}/infrastructure/machineprofile.rgds.yaml") == 0 ]] \
  || { echo "numeric Jetstream flavor IDs cannot be sent to ORC's UUID-only Flavor import" >&2; exit 1; }
machine_profile_rgd="${V2_ROOT}/infrastructure/machineprofile.rgds.yaml"
rg -Fq 'maxVolumeGiB' "${V2_ROOT}/infrastructure/spokeaccount.rgds.yaml"
[[ $(yq -r '.spec.schema.spec.flavorID' "${machine_profile_rgd}") == *'pattern="^[0-9]+$"'* ]] \
  || { echo "MachineProfile must accept Jetstream2 numeric flavor IDs" >&2; exit 1; }
for exact_uuid_field in imageID volumeTypeID; do
  [[ $(yq -r ".spec.schema.spec.${exact_uuid_field}" "${machine_profile_rgd}") == *'{36}'* ]] \
    || { echo "MachineProfile ${exact_uuid_field} must remain UUID-shaped" >&2; exit 1; }
done
[[ $(yq -r '.spec.schema.spec.rootSizeGiB' "${machine_profile_rgd}") == *'minimum=20 maximum=20'* ]] \
  || { echo "v2 node boot volumes must remain exactly 20 GiB" >&2; exit 1; }

for required_text in \
  'cluster-api-autoscaler-node-group-min-size' \
  'capacity.cluster-autoscaler.kubernetes.io/cpu' \
  'capacity.cluster-autoscaler.kubernetes.io/gpu' \
  'csoc.js2.org/pool-class' \
  'managementPolicy: unmanaged'; do
  rg -Fq "${required_text}" "${V2_ROOT}" || { echo "missing v2 contract: ${required_text}" >&2; exit 1; }
done
rg -Fq 'reclaimPolicy: Retain' "${CONFIG_ROOT}/projects/csoc-v2/foundation/storageclasses.yaml" \
  || { echo "foundation must retain the durable Cinder StorageClass" >&2; exit 1; }
if rg -n 'resources-finalizer\.argocd\.argoproj\.io|0\.0\.0\.0/0|kind:[[:space:]]+ApplicationSet|Magnum' "${V2_ROOT}"; then
  echo "unsafe or competing v2 ownership path detected" >&2
  exit 1
fi
if rg -n 'kind:[[:space:]]+(ClusterResourceSet|HelmChartProxy)' "${V2_ROOT}"; then
  echo "spoke delivery must be owned by central Argo, not a CAPI addon object" >&2
  exit 1
fi
if rg -n 'targetRevision:[[:space:]]+(main|master|HEAD)$' "${V2_ROOT}"; then
  echo "floating service source revision detected" >&2
  exit 1
fi

nodepool_rgd="${V2_ROOT}/infrastructure/spokenodepool.rgds.yaml"
[[ $(yq '.spec.resources[] | select(.id == "machinedeployment") | .template.spec | has("replicas")' "$nodepool_rgd") == false ]] \
  || { echo "SpokeNodePool must omit MachineDeployment.spec.replicas for autoscaler ownership" >&2; exit 1; }
rg -Fq 'cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size' "$nodepool_rgd"
if rg -Fq 'capacity.cluster-autoscaler.kubernetes.io/nvidia.com/gpu' "$nodepool_rgd"; then
  echo "autoscaler capacity annotations must use a valid qualified Kubernetes name" >&2
  exit 1
fi

foundation_rgd="${V2_ROOT}/infrastructure/clusterfoundation.yaml"
rg -Fq 'platformClusterName' "$foundation_rgd"
rg -Fq 'clusterAPIMode: incluster-kubeconfig' "$foundation_rgd"
rg -Fq 'clusterAPIKubeconfigSecret: csoc-cluster-api-management-kubeconfig' "$foundation_rgd"
rg -Fq "autoscalerChartVersion" "$foundation_rgd"
rg -Fq "CLUSTER_AUTOSCALER_CHART_VERSION=${CLUSTER_AUTOSCALER_CHART_VERSION}" "${REPO_ROOT}/versions.env"

for service_pin in \
  "JupyterHubInstance:${JUPYTERHUB_CHART_VERSION}" \
  "MonitoringInstance:${KUBE_PROMETHEUS_STACK_CHART_VERSION}" \
  "RegistryCacheInstance:${REGISTRY_CACHE_CHART_VERSION}" \
  "JupyterOutpostInstance:${JUPYTER_OUTPOST_CHART_VERSION}"; do
  service_kind=${service_pin%%:*}; version=${service_pin#*:}
  schema_pin=$(yq eval-all "select(.spec.schema.kind == \"${service_kind}\") | .spec.schema.spec.chartVersion" "${V2_ROOT}/services/"*.rgds.yaml | tr -d '\\')
  rg -Fq "${version}" <<<"${schema_pin}" || { echo "missing service pin ${service_pin}" >&2; exit 1; }
done

matrix="${CATALOG_ROOT}/tests/v2/contract-matrix.yaml"
[[ $(yq -o=json '.supported.machineClasses' "$matrix" | jq -r 'sort | join(",")') == build,cpu,gpu,mig,system ]]
[[ $(yq -o=json '.supported.networkModes' "$matrix" | jq -r 'sort | join(",")') == importedRouted,managedRouted ]]
[[ $(yq -o=json '.supported.endpointModes' "$matrix" | jq -r 'join(",")') == clusterIP ]]
[[ $(yq -o=json '.supported.authModes' "$matrix" | jq -r 'join(",")') == dummy ]]
[[ $(yq -o=json '.supported.serviceTypes' "$matrix" | jq -r 'sort | join(",")') == JupyterHubInstance,MonitoringInstance,SmokeApplication ]]
[[ $(yq -o=json '.renderOnly.serviceTypes' "$matrix" | jq -r 'join(",")') == RegistryCacheInstance ]]
[[ $(yq -o=json '.failClosed.services' "$matrix" | jq -r 'sort | join(",")') == BinderBuildInstance,JupyterOutpostInstance ]]
[[ $(yq -o=json '.rejections' "$matrix" | jq 'length') -ge 14 ]]

bash "${FLEET_ROOT}/scripts/validate-ownership.sh"
bash "${FLEET_ROOT}/tests/ownership/run.sh"
bash "${FLEET_ROOT}/tests/capacity/run.sh"
[[ $(yq -r '.resources | length' "${FLEET_ROOT}/environments/dev/kustomization.yaml") == 0 ]]
bash "${REPO_ROOT}/scripts/tools/validate-kro-v2-rbac.sh"

candidate_dir="${FLEET_ROOT}/environments/staging/accounts/test-poc/hello-app/dev-v2"
candidate_render=$(mktemp)
trap 'rm -f -- "${registration_script:-}" "${candidate_render}"' EXIT
kubectl kustomize "${candidate_dir}" >"${candidate_render}"
bash "${FLEET_ROOT}/scripts/validate-v2-capacity.sh" "${candidate_render}"
[[ $(yq -o=json '.' "${candidate_render}" \
  | jq -sr '[.[] | select(.kind == "MachineProfile") | [.spec.flavorID,.spec.vCPUs,.spec.ramMiB]] | sort | map(join(":")) | join(",")') == 2:2:6144,3:4:15360,3:4:15360 ]] \
  || { echo "staging candidate does not use approved numeric flavor IDs 2/3" >&2; exit 1; }
[[ $(yq -o=json '.' "${candidate_render}" | jq -sr '[.[] | select(.kind == "MachineProfile") | .spec.rootSizeGiB] | unique | join(",")') == 20 ]]
while IFS= read -r commit; do
  git -C "${CONFIG_ROOT}" cat-file -e "${commit}^{commit}" \
    || { echo "candidate references unavailable config commit ${commit}" >&2; exit 1; }
done < <(yq -o=json '.' "${candidate_render}" \
  | jq -sr '.[] | select(.spec.configRepository == "https://github.com/jayadeyemi/config" and .spec.configCommit != "") | .spec.configCommit' \
  | sort -u)

registration_manifest="${REPO_ROOT}/controllers/registration.yaml"
registration_script=$(mktemp)
trap 'rm -f -- "${registration_script}" "${candidate_render}"' EXIT
yq -r 'select(.kind == "ConfigMap" and .metadata.name == "spoke-registration-controller") | .data."reconcile.sh"' "$registration_manifest" >"$registration_script"
sh -n "$registration_script"
for required_text in expirationSeconds 7776000 RENEW_SECONDS=2592000 certificate-authority-data credential-protection credential-purpose DeregistrationBlocked platform-cluster-name csoc-cluster-api-management-kubeconfig WaitingForControlPlaneAPI; do
  rg -Fq "$required_text" "$registration_script" || { echo "registration controller missing ${required_text}" >&2; exit 1; }
done
if rg -n 'foundationRef|WaitingForClusterFoundation' "$registration_script" "${V2_ROOT}/infrastructure/spokeregistration.rgds.yaml"; then
  echo "registration must not wait on the foundation it bootstraps" >&2
  exit 1
fi
if rg -n 'from-file=.*admin\.kubeconfig|client-certificate-data.*admin' "$registration_script"; then
  echo "registration controller exposes the CAPI admin kubeconfig" >&2
  exit 1
fi

sh -n "${REPO_ROOT}/cmp/generate.sh"
for tool_pin in "HELM_VERSION=${HELM_VERSION}" "SOPS_VERSION=${SOPS_VERSION}" "AGE_VERSION=${AGE_VERSION}" "KUSTOMIZE_VERSION=${KUSTOMIZE_VERSION}"; do
  rg -Fq "$tool_pin" "${REPO_ROOT}/cmp/Dockerfile" || { echo "CMP missing ${tool_pin}" >&2; exit 1; }
done
rg -Fq 'emptyDir: {medium: Memory' "${REPO_ROOT}/iac/argocd/values.yaml"
rg -Fq 'runAsNonRoot: true' "${REPO_ROOT}/iac/argocd/values.yaml"
rg -Fq 'ARGOCD_ENV_' "${REPO_ROOT}/cmp/generate.sh"
rg -Fq 'exact 40-character source commit' "${REPO_ROOT}/cmp/generate.sh"

for path in \
  "${CONFIG_ROOT}/projects/csoc-v2/smoke" \
  "${CONFIG_ROOT}/projects/csoc-v2/foundation" \
  "${CONFIG_ROOT}/projects/csoc-v2/jupyterhub" \
  "${CONFIG_ROOT}/projects/csoc-v2/monitoring" \
  "${CONFIG_ROOT}/projects/csoc-v2/registry-cache" \
  "${CONFIG_ROOT}/projects/csoc-v2/binder" \
  "${CONFIG_ROOT}/projects/csoc-v2/outpost" \
  "${GITOPS_ROOT}/argo/csoc-v2/source-pins.yaml"; do
  [[ -e "$path" ]] || { echo "missing reference adaptation: $path" >&2; exit 1; }
done
source_pins="${GITOPS_ROOT}/argo/csoc-v2/source-pins.yaml"
[[ $(yq -r '.data."calico.version"' "$source_pins") == "v${CALICO_VERSION#v}" ]]
[[ $(yq -r '.data."openstack-ccm.version"' "$source_pins") == "$OPENSTACK_CCM_CHART_VERSION" ]]
[[ $(yq -r '.data."openstack-cinder-csi.version"' "$source_pins") == "$OPENSTACK_CINDER_CSI_CHART_VERSION" ]]
[[ $(yq -r '.data."cluster-autoscaler.chart-version"' "$source_pins") == "$CLUSTER_AUTOSCALER_CHART_VERSION" ]]
[[ $(yq -r '.data."cluster-autoscaler.image-version"' "$source_pins") == "v${CLUSTER_AUTOSCALER_VERSION#v}" ]]
if rg -n 'image:[[:space:]]*[^#[:space:]]*:latest([[:space:]]|$)' "${CONFIG_ROOT}/projects/csoc-v2" "${REPO_ROOT}/cmp"; then
  echo "floating latest image in v2 delivery" >&2
  exit 1
fi

bash "${REPO_ROOT}/scripts/tools/validate-v2-renders.sh"

echo "second-generation CSOC static gate passed"
