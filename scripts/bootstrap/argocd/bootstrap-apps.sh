#!/usr/bin/env bash
# Apply the App-of-Apps to hand the management cluster off to GitOps.
# After this script runs, Git is the control plane — use PRs, not kubectl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"

APP_OF_APPS="${REPO_ROOT}/argocd/app-of-apps.yaml"
PROJECT_DIR="${REPO_ROOT}/argocd/projects"
GATE_CONFIGMAP=argocd-manual-manifest-gate

log::step 1 "Verifying Argo CD is running"
kubectl get deployment argocd-server -n argocd >/dev/null \
  || log::die "Argo CD not found. Run 'make argocd-install' first."
kubectl get configmap "${GATE_CONFIGMAP}" -n argocd >/dev/null \
  || log::die "Manual manifest gate missing. Run 'make argocd-manual-smoke' first."

log::step 2 "Applying AppProjects required by the root application"
kubectl apply --server-side -f "${PROJECT_DIR}"

log::step 3 "Applying App-of-Apps"
kubectl apply --server-side -f "${APP_OF_APPS}" -n argocd

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

log::step 4 "Waiting for controller Applications and their CRDs"
wait_application cert-manager
wait_crd certificates.cert-manager.io
wait_application openstack-resource-controller
wait_application capi-operator
wait_application kro

for crd in \
  clusters.cluster.x-k8s.io \
  clusterresourcesets.addons.cluster.x-k8s.io \
  kubeadmcontrolplanes.controlplane.cluster.x-k8s.io \
  openstackclusters.infrastructure.cluster.x-k8s.io \
  openstackclusteridentities.infrastructure.cluster.x-k8s.io \
  helmchartproxies.addons.cluster.x-k8s.io \
  resourcegraphdefinitions.kro.run; do
  wait_crd "${crd}"
done

log::step 5 "Waiting for the SpokeCluster API and fleet handoff"
wait_application capo-identity
wait_application csoc-platform-apis
wait_crd spokeclusters.csoc.js2.org
wait_application spoke-policy
wait_application cluster-registration
wait_application csoc-fleet
wait_application csoc-app-of-apps

log::success "App-of-Apps applied. GitOps owns platform controllers."
log::info "  Watch sync: kubectl get applications -n argocd"
log::info "  Argo UI:    kubectl -n argocd port-forward svc/argocd-server 8443:443"
log::info ""
log::info "Adding a spoke cluster is now a PR to js-poc-csoc-fleet."
