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
if [[ "${CSOC_PROFILE}" == prod ]]; then
  APPLICATION_DIR="${BOOTSTRAP_SOURCE}/argocd/prod/apps"
else
  APPLICATION_DIR="${BOOTSTRAP_SOURCE}/argocd/apps"
fi
RGD_DIR="${CATALOG_SOURCE}/rgds"
RGD_PACKAGE_DIR="${RGD_DIR}/test-poc"
ACCOUNTS_DIR="${FLEET_SOURCE}/accounts"
CSOC_DIR="${FLEET_SOURCE}/csoc"
GATE_CONFIGMAP=argocd-manual-manifest-gate
ARGO_FIELD_MANAGER=csoc-bootstrap

apply_manifest() {
  kubectl apply --server-side --force-conflicts \
    --field-manager="${ARGO_FIELD_MANAGER}" -f "$1"
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
  local application=$1 manifest
  case "${application}" in
    csoc-controllers) manifest="${APPLICATION_DIR}/controllers.yaml" ;;
    csoc-fleet) manifest="${APPLICATION_DIR}/fleet.yaml" ;;
    rgds) manifest="${APPLICATION_DIR}/rgds.yaml" ;;
    *) log::die "Unknown profile Application: ${application}" ;;
  esac
  [[ -f "${manifest}" && $(yq -r '.kind' "${manifest}") == Application ]] \
    || log::die "Profile ${CSOC_PROFILE} does not declare Application/${application}"
  apply_manifest "${manifest}"
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
  [[ -f "${ACCOUNTS_DIR}/kustomization.yaml" && -f "${CSOC_DIR}/kustomization.yaml" ]] \
    || log::die "Fleet entrypoints are unavailable for ${CSOC_FLEET_REVISION}"
fi

log::step 2 "Applying the rgds, csoc-fleet, and csoc-baseline AppProjects"
apply_manifest "${PROJECT_DIR}"

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
apply_manifest "${CONTROLLER_DIR}/kro.yaml"
wait_application kro
wait_crd resourcegraphdefinitions.kro.run

log::step 4 "Manually applying RGD definitions in dependency order"
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

log::step 5 "Manually applying profile-selected fleet instances in graph order"
if [[ "${CSOC_FLEET_ENABLED}" == true ]]; then
  apply_manifest "${CSOC_DIR}/hello-app.yaml"
  wait_instance_ready helloapp csoc kro-system "1800s"

  mapfile -t active_accounts < <(yq -r '.resources[]?' "${ACCOUNTS_DIR}/kustomization.yaml")
  for account in "${active_accounts[@]}"; do
  account_dir="${ACCOUNTS_DIR}/${account}"
  namespace="spokeclusters-${account}"
  for required in identity-config.yaml identity.yaml spoke-config.yaml network.yaml keypair.yaml cluster.yaml; do
    [[ -f "${account_dir}/${required}" ]] \
      || log::die "Active account ${account} is missing ${required}"
  done
  spoke_name=$(yq -er '.metadata.name' "${account_dir}/cluster.yaml")
  network_kind=$(yq -er '.kind' "${account_dir}/network.yaml" | tr '[:upper:]' '[:lower:]')
  apply_manifest "${account_dir}/identity-config.yaml"
  wait_instance_ready immutablespokeconfig "${account}"
  apply_manifest "${account_dir}/identity.yaml"
  wait_instance_ready spokeidentity "${account}"
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
  argocd.argoproj.io/tracking-id- >/dev/null
apply_manifest "${APP_OF_APPS}"
wait_application csoc-app-of-apps

log::success "Manual-first ${CSOC_PROFILE} handoff completed at bootstrap=${CSOC_BOOTSTRAP_REVISION}, catalog=${CSOC_CATALOG_REVISION}, fleet=${CSOC_FLEET_REVISION}."
