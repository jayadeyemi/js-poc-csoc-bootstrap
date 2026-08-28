#!/usr/bin/env bash
# Manually establish controllers, RGDs, and trusted instances before GitOps handoff.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
CATALOG_ROOT="${APP_CATALOG_ROOT:-${WORKSPACE_ROOT}/js-poc-csoc-app-catalog}"
FLEET_ROOT="${FLEET_ROOT:-${WORKSPACE_ROOT}/js-poc-csoc-fleet}"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
csoc::load_profile "${REPO_ROOT}"
export KUBECONFIG="${KUBECONFIG:-${MAGNUM_KUBECONFIG_DIR}/config}"

SOURCE_ROOT=$(mktemp -d)
cleanup_sources() {
  rm -rf -- "${SOURCE_ROOT}"
}
trap cleanup_sources EXIT

archive_revision() {
  local repository=$1 revision=$2 destination=$3
  mkdir -p "${destination}"
  git -C "${repository}" fetch --quiet origin \
    "+refs/heads/${revision}:refs/remotes/origin/${revision}" \
    || log::die "Required Git branch is unavailable: ${repository}@${revision}"
  git -C "${repository}" archive "refs/remotes/origin/${revision}" | tar -x -C "${destination}"
}

BOOTSTRAP_SOURCE="${SOURCE_ROOT}/bootstrap"
CATALOG_SOURCE="${SOURCE_ROOT}/catalog"
FLEET_SOURCE="${SOURCE_ROOT}/fleet"
archive_revision "${REPO_ROOT}" "${CSOC_BOOTSTRAP_REVISION}" "${BOOTSTRAP_SOURCE}"
archive_revision "${CATALOG_ROOT}" "${CSOC_CATALOG_REVISION}" "${CATALOG_SOURCE}"
if [[ "${CSOC_FLEET_ENABLED}" == true ]]; then
  archive_revision "${FLEET_ROOT}" "${CSOC_FLEET_REVISION}" "${FLEET_SOURCE}"
fi
BOOTSTRAP_COMMIT=$(git -C "${REPO_ROOT}" rev-parse "refs/remotes/origin/${CSOC_BOOTSTRAP_REVISION}")
CATALOG_COMMIT=$(git -C "${CATALOG_ROOT}" rev-parse "refs/remotes/origin/${CSOC_CATALOG_REVISION}")
FLEET_COMMIT=disabled
if [[ "${CSOC_FLEET_ENABLED}" == true ]]; then
  FLEET_COMMIT=$(git -C "${FLEET_ROOT}" rev-parse "refs/remotes/origin/${CSOC_FLEET_REVISION}")
fi

APP_OF_APPS="${BOOTSTRAP_SOURCE}/${CSOC_ARGO_ROOT_MANIFEST_REL}"
PROJECT_DIR="${BOOTSTRAP_SOURCE}/argocd/projects"
CONTROLLER_DIR="${BOOTSTRAP_SOURCE}/controllers"
APPLICATION_DIR="${BOOTSTRAP_SOURCE}/${CSOC_APPLICATION_DIR_REL}"
RGD_DIR="${CATALOG_SOURCE}/rgds"
RGD_PACKAGE_DIR="${RGD_DIR}/test-poc"
FLEET_ENV_DIR="${FLEET_SOURCE}/${CSOC_FLEET_PATH}"
ACCOUNTS_DIR="${FLEET_ENV_DIR}/accounts"
GATE_CONFIGMAP=argocd-manual-manifest-gate
ARGO_FIELD_MANAGER=csoc-bootstrap

apply_manifest() {
  kubectl apply --server-side --force-conflicts \
    --field-manager="${ARGO_FIELD_MANAGER}" -f "$1"
}

publish_registration_environment() {
  local server ca_data ca_file ca_sha256
  server=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')
  [[ "${server}" == https://* && "${server}" != https://kubernetes.default.svc* ]] \
    || log::die "Registration requires the externally reachable management API endpoint"
  ca_data=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  if [[ -z "${ca_data}" ]]; then
    ca_file=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority}')
    [[ -n "${ca_file}" && -f "${ca_file}" ]] || log::die "Management kubeconfig has no CA data"
    ca_data=$(base64 -w0 <"${ca_file}")
  fi
  ca_sha256=$(printf '%s' "${ca_data}" | base64 -d | sha256sum | cut -d' ' -f1)
  kubectl create namespace cluster-registration --dry-run=client -o yaml \
    | kubectl apply --server-side -f - >/dev/null
  kubectl create configmap csoc-registration-environment -n cluster-registration \
    --from-literal="profile=${CSOC_PROFILE}" \
    --from-literal="server=${server}" \
    --from-literal="caData=${ca_data}" \
    --from-literal="caSHA256=${ca_sha256}" \
    --dry-run=client -o yaml \
    | yq '.immutable = true' \
    | kubectl apply --server-side -f - >/dev/null
}

wait_application() {
  local application=$1 timeout=${2:-900s} attempts=0
  until kubectl get application "${application}" -n argocd >/dev/null 2>&1; do
    (( attempts += 1 ))
    (( attempts < 60 )) || log::die "Application '${application}' was not created"
    sleep 5
  done
  kubectl wait application "${application}" -n argocd \
    --for=jsonpath='{.status.sync.status}'=Synced --timeout="${timeout}" \
    || log::die "Application '${application}' did not become Synced"
  kubectl wait application "${application}" -n argocd \
    --for=jsonpath='{.status.health.status}'=Healthy --timeout="${timeout}" \
    || log::die "Application '${application}' did not become Healthy"
}

wait_crd() {
  kubectl wait crd "$1" --for=condition=Established --timeout="${2:-900s}" \
    || log::die "CRD '$1' was not established"
}

wait_rgd() {
  local rgd=$1 timeout=${2:-900s}
  kubectl wait resourcegraphdefinition "${rgd}" \
    --for=jsonpath='{.status.state}'=Active --timeout="${timeout}" \
    || log::die "RGD '${rgd}' did not become Active"
}

wait_instance_ready() {
  local resource=$1 name=$2 namespace=${3:-} timeout=${4:-900s}
  local namespace_args=()
  [[ -z "${namespace}" ]] || namespace_args=(--namespace "${namespace}")
  kubectl wait "${resource}/${name}" "${namespace_args[@]}" --for=jsonpath='{.status.ready}'=true \
    --timeout="${timeout}" || log::die "${resource}/${name} did not become ready"
}

apply_profile_application() {
  local application=$1 manifest revision staged
  case "${application}" in
    csoc-controllers) manifest="${APPLICATION_DIR}/controllers.yaml"; revision=${CSOC_BOOTSTRAP_REVISION} ;;
    csoc-fleet) manifest="${APPLICATION_DIR}/fleet.yaml"; revision=${CSOC_FLEET_REVISION} ;;
    rgds) manifest="${APPLICATION_DIR}/rgds.yaml"; revision=${CSOC_CATALOG_REVISION} ;;
    *) log::die "Unknown profile Application: ${application}" ;;
  esac
  [[ -f "${manifest}" && $(yq -r '.kind' "${manifest}") == Application ]] \
    || log::die "Profile ${CSOC_PROFILE} does not declare Application/${application}"
  staged="${SOURCE_ROOT}/${application}-candidate.yaml"
  yq ".spec.source.targetRevision = \"${revision}\"" "${manifest}" >"${staged}"
  apply_manifest "${staged}"
}

log::step 1 "Verifying manual manifest gate and repository layout"
kubectl get deployment argocd-server -n argocd >/dev/null \
  || log::die "Argo CD not found. Run 'make argocd-install' first."
kubectl get configmap "${GATE_CONFIGMAP}" -n argocd >/dev/null \
  || log::die "Manual manifest gate missing. Run 'make argocd-manual-smoke' first."
for gate_key_and_value in \
  "profile=${CSOC_PROFILE}" \
  "bootstrap-commit=${BOOTSTRAP_COMMIT}" \
  "catalog-commit=${CATALOG_COMMIT}" \
  "fleet-commit=${FLEET_COMMIT}"; do
  gate_key=${gate_key_and_value%%=*}
  expected_value=${gate_key_and_value#*=}
  actual_value=$(kubectl get configmap "${GATE_CONFIGMAP}" -n argocd \
    -o "go-template={{ index .data \"${gate_key}\" }}")
  [[ "${actual_value}" == "${expected_value}" ]] \
    || log::die "Manual manifest gate does not match ${gate_key}; rerun 'make argocd-manual-smoke'"
done
[[ -f "${RGD_DIR}/kustomization.yaml" ]] \
  || log::die "RGD definitions are unavailable for ${CSOC_CATALOG_REVISION}"
if [[ "${CSOC_FLEET_ENABLED}" == true ]]; then
  [[ -f "${FLEET_ENV_DIR}/kustomization.yaml" && -d "${ACCOUNTS_DIR}" ]] \
    || log::die "Fleet entrypoints are unavailable for ${CSOC_FLEET_REVISION}"
fi

log::step 2 "Applying the rgds, csoc-fleet, and csoc-baseline AppProjects"
apply_manifest "${PROJECT_DIR}"
publish_registration_environment

log::step 3 "Applying controller Applications in dependency order"
apply_manifest "${CONTROLLER_DIR}/cert-manager.yaml"
wait_application cert-manager
wait_crd certificates.cert-manager.io
apply_manifest "${CONTROLLER_DIR}/orc.yaml"
wait_application openstack-resource-controller
for crd in networks.openstack.k-orc.cloud subnets.openstack.k-orc.cloud \
  routers.openstack.k-orc.cloud routerinterfaces.openstack.k-orc.cloud; do
  wait_crd "${crd}"
done
apply_manifest "${CONTROLLER_DIR}/capi-operator.yaml"
wait_application capi-operator
for crd in clusters.cluster.x-k8s.io clusterresourcesets.addons.cluster.x-k8s.io \
  kubeadmcontrolplanes.controlplane.cluster.x-k8s.io \
  openstackclusters.infrastructure.cluster.x-k8s.io \
  openstackclusteridentities.infrastructure.cluster.x-k8s.io \
  helmchartproxies.addons.cluster.x-k8s.io; do
  wait_crd "${crd}"
done
if [[ "${CSOC_API_GENERATION}" == v2 ]]; then
  apply_manifest "${CONTROLLER_DIR}/kro-v2-rbac.yaml"
fi
apply_manifest "${CONTROLLER_DIR}/kro.yaml"
wait_application kro
wait_crd resourcegraphdefinitions.kro.run
if [[ "${CSOC_API_GENERATION}" == v2 ]]; then
  apply_manifest "${CONTROLLER_DIR}/registration.yaml"
  kubectl -n cluster-registration rollout status \
    deployment/spoke-registration-controller --timeout=300s
fi

log::step 4 "Manually applying RGD definitions in dependency order"
if [[ "${CSOC_API_GENERATION}" == v2 ]]; then
  current_context=$(kubectl config current-context)
  require_empty=false
  [[ "${CSOC_FLEET_ENABLED}" == true ]] || require_empty=true
  APP_CATALOG_ROOT="${CATALOG_SOURCE}" \
    CSOC_V2_ACTIVATION_APPROVED=true \
    CSOC_REQUIRE_EMPTY_V2_FLEET="${require_empty}" \
    CSOC_EXPECTED_CONTEXT="${current_context}" \
    bash "${BOOTSTRAP_SOURCE}/scripts/tools/activate-v2-rgds.sh"
else
apply_manifest "${RGD_PACKAGE_DIR}/configmaps/immutable-spoke-config.rgd.yaml"
wait_rgd immutablespokeconfig
wait_crd immutablespokeconfigs.csoc.js2.org
apply_manifest "${RGD_PACKAGE_DIR}/configmaps/spoke-environment-config.rgd.yaml"
wait_rgd spokeenvironmentconfig
wait_crd spokeenvironmentconfigs.csoc.js2.org
apply_manifest "${RGD_PACKAGE_DIR}/configmaps/spoke-network-import-config.rgd.yaml"
wait_rgd spokenetworkimportconfig
wait_crd spokenetworkimportconfigs.csoc.js2.org
apply_manifest "${RGD_PACKAGE_DIR}/configmaps/spoke-shared-network-config.rgd.yaml"
wait_rgd spokesharednetworkconfig
wait_crd spokesharednetworkconfigs.csoc.js2.org
apply_manifest "${RGD_PACKAGE_DIR}/cluster/v1/spoke-identity.rgd.yaml"
wait_rgd spokeidentity
wait_crd spokeidentities.csoc.js2.org
apply_manifest "${RGD_PACKAGE_DIR}/network"
wait_rgd autoallocatedspokenetwork
wait_rgd dedicatedspokenetwork
wait_rgd importedspokenetwork
wait_rgd isolatedopenstacknetwork
wait_rgd routedspokenetwork
wait_rgd fullymanagedspokenetwork
wait_rgd sharedprovidernetwork
wait_crd autoallocatedspokenetworks.csoc.js2.org
wait_crd dedicatedspokenetworks.csoc.js2.org
wait_crd importedspokenetworks.csoc.js2.org
wait_crd isolatedopenstacknetworks.csoc.js2.org
wait_crd routedspokenetworks.csoc.js2.org
wait_crd fullymanagedspokenetworks.csoc.js2.org
wait_crd sharedprovidernetworks.csoc.js2.org
apply_manifest "${RGD_PACKAGE_DIR}/compute/spoke-server-group.rgd.yaml"
wait_rgd spokeservergroup
wait_crd spokeservergroups.csoc.js2.org
apply_manifest "${RGD_PACKAGE_DIR}/compute/spoke-keypair.rgd.yaml"
wait_rgd spokekeypair
wait_crd spokekeypairs.csoc.js2.org
apply_manifest "${RGD_PACKAGE_DIR}/security/spoke-security-group.rgd.yaml"
wait_rgd spokesecuritygroup
wait_crd spokesecuritygroups.csoc.js2.org
apply_manifest "${RGD_PACKAGE_DIR}/storage/spoke-volume.rgd.yaml"
wait_rgd spokevolume
wait_crd spokevolumes.csoc.js2.org
apply_manifest "${RGD_PACKAGE_DIR}/workloads/hello-app.rgd.yaml"
wait_rgd helloapp
wait_crd helloapps.apps.csoc.js2.org
apply_manifest "${RGD_PACKAGE_DIR}/cluster/v1/spoke-cluster.rgd.yaml"
wait_rgd spokecluster
wait_crd spokeclusters.csoc.js2.org
fi

log::step 5 "Manually applying profile-selected fleet instances in graph order"
if [[ "${CSOC_FLEET_ENABLED}" == true ]]; then
if [[ "${CSOC_API_GENERATION}" == v2 ]]; then
  v2_instances="${SOURCE_ROOT}/v2-instances.yaml"
  kubectl kustomize "${FLEET_ENV_DIR}" >"${v2_instances}"
  CSOC_V2_LIVE_PREFLIGHT_APPROVED=true \
    bash "${BOOTSTRAP_SOURCE}/scripts/tools/preflight-v2-spoke.sh" \
      "${v2_instances}" "${FLEET_SOURCE}/scripts/validate-v2-capacity.sh"
  apply_manifest "${v2_instances}"

  wait_rendered_kind_ready() {
    local kind=$1 timeout=${2:-3600s} name namespace
    while IFS=$'\t' read -r namespace name; do
      [[ -n "${name}" ]] || continue
      wait_instance_ready "${kind,,}" "${name}" "${namespace}" "${timeout}"
    done < <(yq eval-all -r \
      "select(.kind == \"${kind}\") | [.metadata.namespace,.metadata.name] | @tsv" \
      "${v2_instances}" | rg -v '^---$')
  }

  wait_rendered_kind_ready SpokeAccount
  wait_rendered_kind_ready MachineProfile
  wait_rendered_kind_ready SpokeNetwork
  wait_rendered_kind_ready WorkloadCluster 7200s
  wait_rendered_kind_ready SpokeNodePool 7200s
  while IFS=$'\t' read -r namespace name; do
    [[ -n "${name}" ]] || continue
    kubectl wait "spokeregistration/${name}" -n "${namespace}" \
      --for=jsonpath='{.status.registered}'=true --timeout=1800s \
      || log::die "spokeregistration/${name} did not register"
  done < <(yq eval-all -r \
    'select(.kind == "SpokeRegistration") | [.metadata.namespace,.metadata.name] | @tsv' \
    "${v2_instances}" | rg -v '^---$')
  for kind in ClusterFoundation ApplicationBoundary EndpointBinding HubAuthBinding \
    CinderStorageBinding SmokeApplication JupyterHubInstance MonitoringInstance; do
    wait_rendered_kind_ready "${kind}" 3600s
  done
else
  mapfile -t instance_dirs < <(
    find "${ACCOUNTS_DIR}" -type f -name cluster.yaml -printf '%h\n' | sort
  )
  for account_dir in "${instance_dirs[@]}"; do
  for required in identity-config.yaml identity.yaml spoke-config.yaml network.yaml keypair.yaml cluster.yaml; do
    [[ -f "${account_dir}/${required}" ]] \
      || log::die "Active instance ${account_dir#${FLEET_ENV_DIR}/} is missing ${required}"
  done
  identity=$(yq -er '.metadata.name' "${account_dir}/identity-config.yaml")
  spoke_name=$(yq -er '.metadata.name' "${account_dir}/cluster.yaml")
  namespace=$(yq -er '.metadata.namespace' "${account_dir}/cluster.yaml")
  network_kind=$(yq -er '.kind' "${account_dir}/network.yaml" | tr '[:upper:]' '[:lower:]')
  apply_manifest "${account_dir}/identity-config.yaml"
  wait_instance_ready immutablespokeconfig "${identity}"
  apply_manifest "${account_dir}/identity.yaml"
  wait_instance_ready spokeidentity "${identity}"
  apply_manifest "${account_dir}/spoke-config.yaml"
  wait_instance_ready spokeenvironmentconfig "${spoke_name}" "${namespace}"
  apply_manifest "${account_dir}/keypair.yaml"
  wait_instance_ready spokekeypair "${spoke_name}" "${namespace}"
  if [[ -f "${account_dir}/network-import-config.yaml" ]]; then
    apply_manifest "${account_dir}/network-import-config.yaml"
    wait_instance_ready spokenetworkimportconfig "${spoke_name}" "${namespace}"
  fi
  apply_manifest "${account_dir}/network.yaml"
  wait_instance_ready "${network_kind}" "${spoke_name}" "${namespace}"
  apply_manifest "${account_dir}/cluster.yaml"
  wait_instance_ready spokecluster "${spoke_name}" "${namespace}" "3600s"
  if [[ -f "${account_dir}/hello-app.yaml" ]]; then
    apply_manifest "${account_dir}/hello-app.yaml"
    wait_instance_ready helloapp "${spoke_name}" "${namespace}" "1800s"
  fi
  done
fi
else
  log::info "${CSOC_PROFILE} deploys controllers and RGDs only; fleet instances are disabled"
fi

log::step 6 "Enabling Argo ownership only after manual resources are ready"
apply_profile_application csoc-controllers
wait_application csoc-controllers
apply_profile_application rgds
wait_application rgds
if [[ "${CSOC_FLEET_ENABLED}" == true ]]; then
  apply_profile_application csoc-fleet
  wait_application csoc-fleet 1800s
fi
# Older root configurations included app-of-apps.yaml in their own source and
# therefore stamped this object with their tracking ID. The current root is
# host-bootstrapped and intentionally renders only projects and child
# Applications. Remove that stale marker before waiting so prune=false does not
# leave the root permanently OutOfSync as an extraneous self-owned resource.
kubectl annotate application csoc-app-of-apps -n argocd \
  argocd.argoproj.io/tracking-id- --ignore-not-found=true >/dev/null
STAGED_APP_OF_APPS="${SOURCE_ROOT}/app-of-apps-candidate.yaml"
yq ".spec.source.targetRevision = \"${CSOC_BOOTSTRAP_REVISION}\"" \
  "${APP_OF_APPS}" >"${STAGED_APP_OF_APPS}"
expected_environment_revision="environment/${CSOC_PROFILE}"
if [[ "${CSOC_BOOTSTRAP_REVISION}" != "${expected_environment_revision}" \
   || "${CSOC_CATALOG_REVISION}" != "${expected_environment_revision}" \
   || "${CSOC_FLEET_REVISION}" != "${expected_environment_revision}" ]]; then
  # Candidate testing keeps the root Application on the candidate bootstrap
  # commit but leaves its three child Applications on their separately pinned
  # candidate branches. Environment promotion restores normal App-of-Apps
  # ownership without requiring a self-referential commit SHA.
  yq -i '.spec.source.directory.include = "{argocd/projects/*.yaml}"' \
    "${STAGED_APP_OF_APPS}"
fi
apply_manifest "${STAGED_APP_OF_APPS}"
wait_application csoc-app-of-apps

log::success "Manual-first ${CSOC_PROFILE} handoff completed at bootstrap=${CSOC_BOOTSTRAP_REVISION}, catalog=${CSOC_CATALOG_REVISION}, fleet=${CSOC_FLEET_REVISION}."
