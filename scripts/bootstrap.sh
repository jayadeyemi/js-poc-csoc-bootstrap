#!/usr/bin/env bash
# Full orchestration: build container → provision Magnum → install CAPI → provision workload cluster.
# Each step is idempotent; re-running is safe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
source "${REPO_ROOT}/scripts/lib/logging.sh"

CLUSTER_DIR="${1:-${REPO_ROOT}/iac/capi/clusters/example-cluster}"

log::info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log::info " Jetstream2 CSOC Bootstrap"
log::info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

log::step A "Build management container"
bash "${REPO_ROOT}/scripts/container/build.sh"

log::step B "Provision Magnum management cluster"
bash "${REPO_ROOT}/scripts/magnum/provision.sh"

log::step C "Wait for Magnum cluster to become active"
bash "${REPO_ROOT}/scripts/magnum/wait.sh"

log::step D "Retrieve management cluster kubeconfig"
bash "${REPO_ROOT}/scripts/magnum/kubeconfig.sh"

log::step E "Install CAPI + CAPO controllers"
bash "${REPO_ROOT}/scripts/capi/install-controllers.sh"

log::step F "Provision workload cluster via CAPI"
bash "${REPO_ROOT}/scripts/capi/provision-cluster.sh" "${CLUSTER_DIR}"

log::success "Bootstrap complete."
