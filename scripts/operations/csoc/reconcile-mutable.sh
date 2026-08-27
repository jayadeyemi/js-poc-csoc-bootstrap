#!/usr/bin/env bash
# Apply only the mutable Magnum default-worker min/max bounds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
csoc::load_profile "${REPO_ROOT}"

CONFIRM=""
while (( $# > 0 )); do
  case "$1" in
    --confirm) CONFIRM=${2:-}; shift 2 ;;
    *) log::die "Usage: $0 --confirm <exact-cluster-name>" ;;
  esac
done
[[ "${CONFIRM}" == "${MAGNUM_CLUSTER_NAME}" ]] \
  || log::die "Confirmation must exactly match ${MAGNUM_CLUSTER_NAME}"

log::step 1 "Validate every cluster declaration before changing live bounds"
bash "${REPO_ROOT}/scripts/tools/validate-clusters.sh"
log::step 2 "Reject rename or immutable spec drift"
CSOC_PLAN_FAIL_ON_REPLACEMENT=true bash "${REPO_ROOT}/scripts/operations/csoc/plan.sh"
log::step 3 "Run read-only OpenStack, quota, and ownership preflight"
bash "${REPO_ROOT}/scripts/bootstrap/magnum/preflight.sh"
log::step 4 "Reconcile only default-worker bounds"
bash "${REPO_ROOT}/scripts/bootstrap/magnum/configure-nodegroup.sh"
log::success "Mutable CSOC bounds were reconciled; no rename or immutable spec was changed"
