#!/usr/bin/env bash
# Idempotently provision a Magnum cluster on Jetstream2.
# Sources iac/magnum/cluster.env for all parameters.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"
source "${REPO_ROOT}/scripts/lib/openstack.sh"

CLUSTER_ENV="${REPO_ROOT}/iac/magnum/cluster.env"
[[ -f "${CLUSTER_ENV}" ]] || log::die "Cluster env file not found: ${CLUSTER_ENV}"
# shellcheck source=iac/magnum/cluster.env
source "${CLUSTER_ENV}"

log::step 1 "Verifying OpenStack authentication"
os::auth_check

# ── Cluster template ──────────────────────────────────────────────────────────
log::step 2 "Ensuring cluster template '${MAGNUM_TEMPLATE_NAME}'"

TEMPLATE_ARGS=(
  --image            "${MAGNUM_IMAGE}"
  --external-network "${MAGNUM_EXTERNAL_NETWORK}"
  --dns-nameserver   "${MAGNUM_DNS_NAMESERVER}"
  --master-flavor    "${MAGNUM_MASTER_FLAVOR}"
  --flavor           "${MAGNUM_WORKER_FLAVOR}"
  --network-driver   "${MAGNUM_NETWORK_DRIVER}"
  --docker-volume-size 50
  --coe              kubernetes
  --public
  --labels           "${MAGNUM_LABELS}"
)

TEMPLATE_ID=$(os::ensure_cluster_template "${MAGNUM_TEMPLATE_NAME}" "${TEMPLATE_ARGS[@]}")
log::success "Template ID: ${TEMPLATE_ID}"

# ── Cluster ───────────────────────────────────────────────────────────────────
log::step 3 "Ensuring Magnum cluster '${MAGNUM_CLUSTER_NAME}'"

CLUSTER_STATUS=$(os::cluster_status "${MAGNUM_CLUSTER_NAME}")

case "${CLUSTER_STATUS}" in
  CREATE_COMPLETE)
    log::success "Cluster '${MAGNUM_CLUSTER_NAME}' already exists and is active."
    ;;
  CREATE_IN_PROGRESS)
    log::info "Cluster '${MAGNUM_CLUSTER_NAME}' is already being created."
    ;;
  NOT_FOUND)
    log::info "Creating cluster '${MAGNUM_CLUSTER_NAME}' ..."

    CLUSTER_ARGS=(
      --cluster-template "${MAGNUM_TEMPLATE_NAME}"
      --master-count     "${MAGNUM_MASTER_COUNT}"
      --node-count       "${MAGNUM_NODE_COUNT}"
    )

    [[ -n "${MAGNUM_KEYPAIR}" ]] && CLUSTER_ARGS+=(--keypair "${MAGNUM_KEYPAIR}")
    [[ -n "${MAGNUM_FIXED_NETWORK}" ]] && CLUSTER_ARGS+=(--fixed-network "${MAGNUM_FIXED_NETWORK}")
    [[ -n "${MAGNUM_FIXED_SUBNET}" ]]  && CLUSTER_ARGS+=(--fixed-subnet  "${MAGNUM_FIXED_SUBNET}")

    openstack coe cluster create "${MAGNUM_CLUSTER_NAME}" "${CLUSTER_ARGS[@]}"
    log::success "Cluster creation requested. Run 'make magnum-wait' to watch progress."
    ;;
  CREATE_FAILED|*FAILED*)
    log::die "Cluster '${MAGNUM_CLUSTER_NAME}' is in a failed state: ${CLUSTER_STATUS}. Check Magnum logs."
    ;;
  *)
    log::warn "Cluster '${MAGNUM_CLUSTER_NAME}' is in unexpected state: ${CLUSTER_STATUS}"
    ;;
esac
