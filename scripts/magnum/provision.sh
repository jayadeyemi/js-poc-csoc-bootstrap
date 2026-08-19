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

STATE_FILE="${MAGNUM_STATE_FILE:-${REPO_ROOT}/.state/magnum-cluster.json}"
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
elif (( $# > 0 )); then
  log::die "Usage: $0 [--dry-run]"
fi

log::step 1 "Running read-only preflight"
bash "${REPO_ROOT}/scripts/magnum/preflight.sh"

# ── Cluster ───────────────────────────────────────────────────────────────────
log::step 2 "Ensuring Magnum cluster '${MAGNUM_CLUSTER_NAME}'"

mapfile -t MATCHING_CLUSTER_IDS < <(os::cluster_ids_by_name "${MAGNUM_CLUSTER_NAME}")
if (( ${#MATCHING_CLUSTER_IDS[@]} == 1 )); then
  CLUSTER_ID=$(os::verify_owned_cluster "${STATE_FILE}" "${MAGNUM_CLUSTER_NAME}")
  CLUSTER_STATUS=$(os::cluster_status "${CLUSTER_ID}")
else
  CLUSTER_ID=""
  CLUSTER_STATUS="NOT_FOUND"
fi

case "${CLUSTER_STATUS}" in
  CREATE_COMPLETE)
    log::success "Owned cluster '${MAGNUM_CLUSTER_NAME}' is active (${CLUSTER_ID})."
    ;;
  CREATE_IN_PROGRESS)
    log::info "Owned cluster '${MAGNUM_CLUSTER_NAME}' is being created (${CLUSTER_ID})."
    ;;
  NOT_FOUND)
    if [[ "${DRY_RUN}" == true ]]; then
      log::success "Dry-run passed; cluster creation would use template ${MAGNUM_TEMPLATE_ID}"
      exit 0
    fi
    log::info "Creating cluster '${MAGNUM_CLUSTER_NAME}' ..."

    CLUSTER_ARGS=(
      --cluster-template "${MAGNUM_TEMPLATE_ID}"
      --master-count     "${MAGNUM_MASTER_COUNT}"
      --node-count       "${MAGNUM_NODE_COUNT}"
      --master-flavor    "${MAGNUM_MASTER_FLAVOR}"
      --flavor           "${MAGNUM_WORKER_FLAVOR}"
      --keypair          "${MAGNUM_KEYPAIR}"
    )

    [[ -n "${MAGNUM_FIXED_NETWORK}" ]] && CLUSTER_ARGS+=(--fixed-network "${MAGNUM_FIXED_NETWORK}")
    [[ -n "${MAGNUM_FIXED_SUBNET}" ]]  && CLUSTER_ARGS+=(--fixed-subnet  "${MAGNUM_FIXED_SUBNET}")

    CLUSTER_ID=$(openstack coe cluster create "${MAGNUM_CLUSTER_NAME}" \
      "${CLUSTER_ARGS[@]}" -f value -c uuid)
    [[ -n "${CLUSTER_ID}" ]] || log::die "Magnum did not return a cluster UUID"

    mkdir -p "$(dirname "${STATE_FILE}")"
    STATE_TMP=$(mktemp "${STATE_FILE}.tmp.XXXXXX")
    jq -n \
      --arg cluster_id "${CLUSTER_ID}" \
      --arg cluster_name "${MAGNUM_CLUSTER_NAME}" \
      --arg template_id "${MAGNUM_TEMPLATE_ID}" \
      --arg created_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
      '{cluster_id:$cluster_id,cluster_name:$cluster_name,template_id:$template_id,created_at:$created_at}' \
      >"${STATE_TMP}"
    chmod 600 "${STATE_TMP}"
    mv "${STATE_TMP}" "${STATE_FILE}"

    log::success "Cluster creation requested: ${CLUSTER_ID}"
    log::info "Run 'make magnum-wait' to watch progress."
    ;;
  CREATE_FAILED|*FAILED*)
    log::die "Owned cluster '${CLUSTER_ID}' is in a failed state: ${CLUSTER_STATUS}."
    ;;
  *)
    log::warn "Cluster '${MAGNUM_CLUSTER_NAME}' is in unexpected state: ${CLUSTER_STATUS}"
    ;;
esac
