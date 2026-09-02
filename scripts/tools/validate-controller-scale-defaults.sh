#!/usr/bin/env bash
# Validate exposed controller defaults, renamed catalogs, and scale inventory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
CATALOG_ROOT="${APP_CATALOG_ROOT:-${WORKSPACE_ROOT}/js-poc-csoc-app-catalog}"
FLEET_ROOT="${FLEET_ROOT:-${WORKSPACE_ROOT}/js-poc-csoc-fleet}"

die() {
  printf 'controller/scale validation: %s\n' "$*" >&2
  exit 1
}

[[ -d "${CATALOG_ROOT}/rgds/v1-samples" ]] || die "v1-samples package is missing"
[[ -d "${CATALOG_ROOT}/rgds/v2-hubs" ]] || die "v2-hubs package is missing"
[[ ! -d "${CATALOG_ROOT}/rgds/test-poc" || -z $(find "${CATALOG_ROOT}/rgds/test-poc" -type f -print -quit) ]] \
  || die "legacy v1 catalog package still contains files"
[[ ! -d "${CATALOG_ROOT}/rgds/v2" || -z $(find "${CATALOG_ROOT}/rgds/v2" -type f -print -quit) ]] \
  || die "legacy v2 catalog package still contains files"
! rg -q 'rgds/(test-poc|v2)(/|$)' "${REPO_ROOT}/scripts" "${CATALOG_ROOT}"   || die "legacy catalog path is still referenced"

waves=$(
  for definition in \
    immutable-spoke-config:-16 \
    spoke-environment-config:-15 \
    spoke-network-import-config:-14 \
    spoke-shared-network-config:-13; do
    file=${definition%%:*}
    expected=${definition##*:}
    actual=$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave"' \
      "${CATALOG_ROOT}/rgds/v1-samples/configmaps/${file}.rgd.yaml")
    printf '%s:%s\n' "${expected}" "${actual}"
  done
)
[[ "${waves}" == $'-16:-16\n-15:-15\n-14:-14\n-13:-13' ]] \
  || die "v1 configuration RGDs must retain separate dependency waves"

kro_values=$(yq -r '.spec.source.helm.values' "${REPO_ROOT}/controllers/kro.yaml")
[[ $(yq -r '.deployment.replicaCount' <<<"${kro_values}") == 1 ]]   || die "KRO replica default is not exposed"
[[ $(yq -r '[.config.clientQps,.config.clientBurst,
  .config.resourceGraphDefinitionConcurrentReconciles,
  .config.graphRevisionConcurrentReconciles,
  .config.dynamicControllerConcurrentReconciles,
  .config.dynamicControllerRateLimiterRateLimit,
  .config.dynamicControllerRateLimiterBurstLimit,
  .config.instance.requeueInterval] | join(",")' <<<"${kro_values}")   == "100,150,1,1,1,10,100,3s" ]] || die "KRO scale defaults drifted"

capi_values=$(yq -r '.spec.source.helm.values' "${REPO_ROOT}/controllers/capi-operator.yaml")
[[ $(yq -r '[.replicaCount,.resources.manager.requests.cpu,
  .resources.manager.requests.memory,.resources.manager.limits.cpu,
  .resources.manager.limits.memory] | join(",")' <<<"${capi_values}")   == "1,100m,100Mi,100m,300Mi" ]] || die "CAPI Operator defaults drifted"
[[ $(yq -r '.enableHelmHook' <<<"${capi_values}") == false ]] \
  || die "CAPI Provider CRs must remain Argo-managed rather than one-shot Helm hooks"
core_args=$(yq -r '.core.cluster-api.deployment.containers[] | select(.name == "manager") | .args' <<<"${capi_values}")
[[ $(yq -r '[(."--cluster-concurrency"),(."--machine-concurrency"),
  (."--machineset-concurrency"),(."--machinedeployment-concurrency"),
  (."--clusterresourceset-concurrency"),(."--clustercache-concurrency"),
  (."--kube-api-qps"),(."--kube-api-burst")] | join(",")' <<<"${core_args}")   == "10,10,10,10,10,100,20,30" ]] || die "CAPI core defaults drifted"
bootstrap_args=$(yq -r '.bootstrap.kubeadm.deployment.containers[] | select(.name == "manager") | .args' <<<"${capi_values}")
[[ $(yq -r '[(."--kubeadmconfig-concurrency"),(."--clustercache-concurrency"),
  (."--kube-api-qps"),(."--kube-api-burst")] | join(",")' <<<"${bootstrap_args}")   == "10,100,20,30" ]] || die "kubeadm bootstrap defaults drifted"
control_plane_args=$(yq -r '.controlPlane.kubeadm.deployment.containers[] | select(.name == "manager") | .args' <<<"${capi_values}")
[[ $(yq -r '[(."--kubeadmcontrolplane-concurrency"),(."--clustercache-concurrency"),
  (."--kube-api-qps"),(."--kube-api-burst")] | join(",")' <<<"${control_plane_args}")   == "10,100,20,30" ]] || die "kubeadm control-plane defaults drifted"
capo_args=$(yq -r '.infrastructure.openstack.deployment.containers[] | select(.name == "manager") | .args' <<<"${capi_values}")
[[ $(yq -r '[(."--openstackcluster-concurrency"),(."--openstackmachine-concurrency"),
  (."--openstackmachinetemplate-concurrency"),(."--scope-cache-max-size"),
  (."--kube-api-qps"),(."--kube-api-burst")] | join(",")' <<<"${capo_args}")   == "10,10,10,10,20,30" ]] || die "CAPO defaults drifted"
caaph_args=$(yq -r '.addon.helm.deployment.containers[] | select(.name == "manager") | .args' <<<"${capi_values}")
[[ $(yq -r '[(."--helm-chart-proxy-concurrency"),(."--helm-release-proxy-concurrency"),
  (."--kube-api-qps"),(."--kube-api-burst")] | join(",")' <<<"${caaph_args}")   == "10,10,20,30" ]] || die "CAAPH defaults drifted"

bad_provider_flags=$(yq -r '[.core.cluster-api,.bootstrap.kubeadm,.controlPlane.kubeadm,
  .infrastructure.openstack,.addon.helm][]
  | .deployment.containers[] | select(.name == "manager") | .args | keys[]' \
  <<<"${capi_values}" | rg -v '^--' || true)
[[ -z "${bad_provider_flags}" ]] || die "CAPI provider arguments must be literal --flags"

[[ $(yq -r '.spec.source.path' "${REPO_ROOT}/controllers/orc.yaml") == config/default ]]   || die "ORC must render the pinned Kustomize package"
[[ $(yq -r '.spec.source.kustomize.patches[0].target.name' "${REPO_ROOT}/controllers/orc.yaml") == controller-manager ]] \
  || die "ORC patch must target the upstream pre-prefix Deployment name"
orc_patch=$(yq -r '.spec.source.kustomize.patches[0].patch' "${REPO_ROOT}/controllers/orc.yaml")
[[ $(yq -r '[.spec.template.spec.containers[0].image,
  (.spec.template.spec.containers[0].args[] | select(. == "--scope-cache-max-size=10"))] | join(",")' \
  <<<"${orc_patch}") == "quay.io/orc/openstack-resource-controller:v2.6.0,--scope-cache-max-size=10" ]] \
  || die "ORC config/default image or cache patch is invalid"
rg -q 'requests: \{cpu: 10m, memory: 64Mi\}' "${REPO_ROOT}/controllers/orc.yaml"   || die "ORC resource defaults are not exposed"

bootstrap_script="${REPO_ROOT}/scripts/bootstrap/argocd/bootstrap-apps.sh"
kro_rbac_line=$(rg -n -F 'apply_manifest "${CONTROLLER_DIR}/kro-v2-rbac.yaml"' "${bootstrap_script}" | cut -d: -f1)
first_rgd_line=$(rg -n -F 'apply_manifest "${RGD_PACKAGE_DIR}/configmaps/immutable-spoke-config.rgd.yaml"' "${bootstrap_script}" | cut -d: -f1)
[[ -n "${kro_rbac_line}" && -n "${first_rgd_line}" && "${kro_rbac_line}" -lt "${first_rgd_line}" ]] \
  || die "KRO aggregate RBAC must be effective before the first generated API is compiled"
rg -q 'kubectl auth can-i.*\\' "${bootstrap_script}" \
  || die "KRO aggregate RBAC readiness check is missing"
registration_environment_line=$(rg -n -F 'ensure_registration_environment' "${bootstrap_script}" | tail -1 | cut -d: -f1)
controller_application_line=$(rg -n -F 'apply_profile_application csoc-controllers' "${bootstrap_script}" | cut -d: -f1)
[[ -n "${registration_environment_line}" && -n "${controller_application_line}" \
   && "${registration_environment_line}" -lt "${controller_application_line}" ]] \
  || die "Registration environment must exist before the controller Application"
rg -q 'kubectl config view --raw --minify --flatten' "${bootstrap_script}" \
  || die "Registration environment must derive trust data from the exact management kubeconfig"
rg -q 'if kubectl get application csoc-app-of-apps' "${bootstrap_script}" \
  || die "First install must guard legacy root Application annotation cleanup"
! rg -q 'annotate .*--ignore-not-found' "${bootstrap_script}" \
  || die "kubectl annotate does not support --ignore-not-found"

[[ $(yq -r '[.configs.params."controller.status.processors",
  .configs.params."controller.operation.processors",
  .configs.params."controller.kubectl.parallelism.limit",
  .configs.params."controller.k8s.client.qps",
  .configs.params."controller.k8s.client.burst",
  .configs.params."reposerver.parallelism.limit"] | join(",")'   "${REPO_ROOT}/iac/argocd/values.yaml") == "20,10,20,50,100,1" ]]   || die "Argo scale defaults drifted"

inventory="${FLEET_ROOT}/accounts/staging/benchmarks/v1-scale/inventory.yaml"
if [[ -f "${inventory}" ]]; then
  [[ $(yq -r '.spec.spokes | length' "${inventory}") == 11 ]]     || die "benchmark must contain eleven spokes"
  [[ $(yq -r '[.spec.spokes[].name] | unique | length' "${inventory}") == 11 ]]     || die "benchmark spoke names are not unique"
  [[ $(yq -r '[.spec.spokes[].nodeCIDR] | unique | length' "${inventory}") == 11 ]]     || die "benchmark node CIDRs are not unique"
  [[ $(yq -r '.spec.spokes[] | .controlPlanes + .minWorkers' "${inventory}" | awk '{total += $1} END {print total}') == 35 ]] \
    || die "benchmark minimum server total is not 35"
  [[ $(yq -r '.spec.spokes[] | select(.phase == "batch") |
    .controlPlanes + .minWorkers' "${inventory}" | awk '{total += $1} END {print total}') == 33 ]] \
    || die "batch minimum server total is not 33"
  [[ $(yq -r '.spec.spokes[] | select(.phase == "single") |
    .controlPlanes + .minWorkers' "${inventory}" | awk '{total += $1} END {print total}') == 2 ]] \
    || die "single minimum server total is not 2"
  [[ $(yq eval-all 'select(.kind == "Application") | .metadata.name'     "${REPO_ROOT}/argocd/environments/staging/apps/v1-scale-benchmark.yaml" | rg -c '^csoc-v1-scale-') == 11 ]]     || die "eleven manual benchmark Applications are required"
  ! yq eval-all 'select(.kind == "Application" and .spec.syncPolicy.automated != null) |
    .metadata.name' "${REPO_ROOT}/argocd/environments/staging/apps/v1-scale-benchmark.yaml" | rg -q . \
    || die "benchmark Applications must remain manual"
  [[ $(yq -r '.spec.syncPolicy.automated // "manual"'     "${REPO_ROOT}/argocd/environments/staging/apps/fleet.yaml") == manual ]]     || die "ordinary staging fleet Application must remain manual"
  rg -q '^CSOC_BOOTSTRAP_FLEET_INSTANCES=false$'     "${REPO_ROOT}/iac/csoc/profiles/staging.profile"     || die "staging bootstrap fleet boundary is not disabled"
  ! rg -q 'scale-[0-9][0-9]' "${FLEET_ROOT}/accounts/staging/kustomization.yaml"     || die "ordinary staging Kustomization includes benchmark tuples"
  rg -q 'set-context.*--namespace=argocd' "${REPO_ROOT}/scripts/operations/benchmarks/run-v1-scale.sh" \
    || die "benchmark runner must scope Argo core mode to the argocd namespace"
  rg -q 'credentials::metadata' "${REPO_ROOT}/scripts/operations/benchmarks/preflight-v1-scale.sh" \
    || die "benchmark preflight must verify live credential metadata"
  rg -q 'credentials::require_unexpired' "${REPO_ROOT}/scripts/operations/benchmarks/preflight-v1-scale.sh" \
    || die "benchmark preflight must reject expired credentials"
  ! rg -q 'auth\.project_id' "${REPO_ROOT}/scripts/operations/benchmarks/preflight-v1-scale.sh" \
    || die "benchmark preflight must derive the project from authenticated metadata"
  ! rg -q 'server list --project|volume list --project' \
      "${REPO_ROOT}/scripts/operations/benchmarks/preflight-v1-scale.sh" \
      "${REPO_ROOT}/scripts/operations/benchmarks/run-v1-scale.sh" \
    || die "restricted benchmark credentials must not request all-tenant server or volume inventory"
  ! rg -q '\| add' "${REPO_ROOT}/scripts/operations/benchmarks/preflight-v1-scale.sh" \
    || die "benchmark preflight must use pinned-yq-compatible numeric sums"
  bash -n "${REPO_ROOT}/scripts/operations/benchmarks/run-v1-scale.sh"
fi

printf 'controller defaults, catalog paths, and scale inventory passed\n'
