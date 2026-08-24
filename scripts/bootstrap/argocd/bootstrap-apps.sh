#!/usr/bin/env bash
# Apply the App-of-Apps to hand the management cluster off to GitOps.
# After this script runs, Git is the control plane — use PRs, not kubectl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"

APP_OF_APPS="${REPO_ROOT}/argocd/app-of-apps.yaml"
PROJECT_DIR="${REPO_ROOT}/argocd/projects"
APPLICATION_DIR="${REPO_ROOT}/argocd/apps"
APPLICATIONSET_DIR="${REPO_ROOT}/argocd/applicationsets"
GATE_CONFIGMAP=argocd-manual-manifest-gate
ARGO_FIELD_MANAGER=argocd-controller

apply_manifest() {
  kubectl apply --server-side --field-manager="${ARGO_FIELD_MANAGER}" -f "$1"
}

wait_application() {
  local application=$1 timeout=${2:-900s}
  local attempts=0
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
  local crd=$1 timeout=${2:-900s}
  kubectl wait crd "${crd}" --for=condition=Established --timeout="${timeout}" \
    || log::die "CRD '${crd}' was not established"
}

log::step 1 "Verifying Argo CD is running"
kubectl get deployment argocd-server -n argocd >/dev/null \
  || log::die "Argo CD not found. Run 'make argocd-install' first."
kubectl get configmap "${GATE_CONFIGMAP}" -n argocd >/dev/null \
  || log::die "Manual manifest gate missing. Run 'make argocd-manual-smoke' first."

log::step 2 "Applying AppProjects required by the root application"
apply_manifest "${PROJECT_DIR}"

log::step 3 "Applying controller Applications in dependency order"
apply_manifest "${APPLICATION_DIR}/cert-manager.yaml"
wait_application cert-manager
wait_crd certificates.cert-manager.io

apply_manifest "${APPLICATION_DIR}/orc.yaml"
wait_application openstack-resource-controller

apply_manifest "${APPLICATION_DIR}/capi-operator.yaml"
wait_application capi-operator

for crd in \
  clusters.cluster.x-k8s.io \
  clusterresourcesets.addons.cluster.x-k8s.io \
  kubeadmcontrolplanes.controlplane.cluster.x-k8s.io \
  openstackclusters.infrastructure.cluster.x-k8s.io \
  openstackclusteridentities.infrastructure.cluster.x-k8s.io \
  helmchartproxies.addons.cluster.x-k8s.io; do
  wait_crd "${crd}"
done

apply_manifest "${APPLICATION_DIR}/kro.yaml"
wait_application kro
wait_crd resourcegraphdefinitions.kro.run

log::step 4 "Applying platform, registration, and fleet Applications"
apply_manifest "${APPLICATION_DIR}/capo-identity.yaml"
wait_application capo-identity
apply_manifest "${APPLICATION_DIR}/platform-apis.yaml"
wait_application csoc-platform-apis
wait_crd spokeclusters.csoc.js2.org
apply_manifest "${APPLICATION_DIR}/spoke-policy.yaml"
wait_application spoke-policy
apply_manifest "${APPLICATION_DIR}/cluster-registration.yaml"
wait_application cluster-registration
apply_manifest "${APPLICATION_DIR}/fleet.yaml"
wait_application csoc-fleet

log::step 5 "Applying ApplicationSets and handing ownership to App-of-Apps"
apply_manifest "${APPLICATIONSET_DIR}"
apply_manifest "${APP_OF_APPS}"
wait_application csoc-app-of-apps

log::success "App-of-Apps applied. GitOps owns platform controllers."
log::info "  Watch sync: kubectl get applications -n argocd"
log::info "  Argo UI:    kubectl -n argocd port-forward svc/argocd-server 8443:443"
log::info ""
log::info "Adding a spoke cluster is now a PR to js-poc-csoc-fleet."
