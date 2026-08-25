#!/usr/bin/env bash
# Manually establish controllers, RGDs, and trusted instances before GitOps handoff.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
CATALOG_ROOT="${APP_CATALOG_ROOT:-${WORKSPACE_ROOT}/js-poc-csoc-app-catalog}"
FLEET_ROOT="${FLEET_ROOT:-${WORKSPACE_ROOT}/js-poc-csoc-fleet}"
source "${REPO_ROOT}/scripts/lib/logging.bash"

APP_OF_APPS="${REPO_ROOT}/argocd/app-of-apps.yaml"
PROJECT_DIR="${REPO_ROOT}/argocd/projects"
APPLICATION_DIR="${REPO_ROOT}/argocd/apps"
CONTROLLER_DIR="${REPO_ROOT}/controllers"
RGD_DIR="${CATALOG_ROOT}/rgds"
ACCOUNT_DIR="${FLEET_ROOT}/accounts/test-poc"
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

log::step 1 "Verifying manual manifest gate and repository layout"
kubectl get deployment argocd-server -n argocd >/dev/null \
  || log::die "Argo CD not found. Run 'make argocd-install' first."
kubectl get configmap "${GATE_CONFIGMAP}" -n argocd >/dev/null \
  || log::die "Manual manifest gate missing. Run 'make argocd-manual-smoke' first."
[[ -f "${RGD_DIR}/kustomization.yaml" && -f "${ACCOUNT_DIR}/kustomization.yaml" ]] \
  || log::die "RGD definitions or fleet account test-poc are unavailable"

log::step 2 "Applying the rgds and csoc-fleet AppProjects"
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
apply_manifest "${RGD_DIR}/configmaps/immutable-spoke-config.rgd.yaml"
wait_rgd immutablespokeconfig
wait_crd immutablespokeconfigs.csoc.js2.org
apply_manifest "${RGD_DIR}/configmaps/spoke-environment-config.rgd.yaml"
wait_rgd spokeenvironmentconfig
wait_crd spokeenvironmentconfigs.csoc.js2.org
apply_manifest "${RGD_DIR}/cluster/v1/spoke-identity.rgd.yaml"
wait_rgd spokeidentity
wait_crd spokeidentities.csoc.js2.org
apply_manifest "${RGD_DIR}/network"
wait_rgd autoallocatedspokenetwork
wait_rgd dedicatedspokenetwork
wait_crd autoallocatedspokenetworks.csoc.js2.org
wait_crd dedicatedspokenetworks.csoc.js2.org
apply_manifest "${RGD_DIR}/workloads/hello-app.rgd.yaml"
wait_rgd helloapp
wait_crd helloapps.apps.csoc.js2.org
apply_manifest "${RGD_DIR}/cluster/v1/spoke-cluster.rgd.yaml"
wait_rgd spokecluster
wait_crd spokeclusters.csoc.js2.org

log::step 5 "Manually applying fleet account test-poc in graph order"
apply_manifest "${ACCOUNT_DIR}/identity-config.yaml"
wait_instance_ready immutablespokeconfig test-poc
apply_manifest "${ACCOUNT_DIR}/identity.yaml"
wait_instance_ready spokeidentity test-poc
apply_manifest "${ACCOUNT_DIR}/spoke-config.yaml"
wait_instance_ready spokeenvironmentconfig poc-tenant-dev spokeclusters-test-poc
apply_manifest "${ACCOUNT_DIR}/network.yaml"
wait_instance_ready dedicatedspokenetwork poc-tenant-dev spokeclusters-test-poc
apply_manifest "${ACCOUNT_DIR}/cluster.yaml"
wait_instance_ready spokecluster poc-tenant-dev spokeclusters-test-poc "1800s"
apply_manifest "${ACCOUNT_DIR}/hello-app.yaml"
wait_instance_ready helloapp poc-tenant-dev spokeclusters-test-poc

log::step 6 "Enabling Argo ownership only after manual resources are ready"
apply_manifest "${APPLICATION_DIR}/controllers.yaml"
wait_application csoc-controllers
apply_manifest "${APPLICATION_DIR}/rgds.yaml"
wait_application rgds
apply_manifest "${APPLICATION_DIR}/fleet.yaml"
wait_application csoc-fleet 1800s
apply_manifest "${APP_OF_APPS}"
wait_application csoc-app-of-apps

log::success "Manual-first handoff completed; GitOps owns the rgds and csoc-fleet projects."
