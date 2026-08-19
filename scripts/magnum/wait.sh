#!/usr/bin/env bash
# Poll until the Magnum cluster reaches a target status (default: CREATE_COMPLETE).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"
source "${REPO_ROOT}/scripts/lib/openstack.sh"
source "${REPO_ROOT}/scripts/lib/credentials.sh"

source "${REPO_ROOT}/iac/magnum/cluster.env"

TIMEOUT="${MAGNUM_WAIT_TIMEOUT:-2700}"
INTERVAL="${MAGNUM_WAIT_INTERVAL:-15}"
DIAG_AFTER="${MAGNUM_NO_WORKER_DIAG_AFTER:-1200}"
STATE_FILE="${MAGNUM_STATE_FILE:-${REPO_ROOT}/.state/magnum-cluster.json}"
credentials::configure_magnum
CLUSTER_ID=$(os::verify_owned_cluster "${STATE_FILE}" "${MAGNUM_CLUSTER_NAME}")

log::info "Waiting for owned cluster ${CLUSTER_ID} → complete and HEALTHY (timeout ${TIMEOUT}s)"

deadline=$((SECONDS + TIMEOUT))
diagnosed=false
while (( SECONDS < deadline )); do
  CLUSTER_JSON=$(openstack coe cluster show "${CLUSTER_ID}" -f json 2>/dev/null) \
    || log::die "Owned cluster '${CLUSTER_ID}' is no longer visible"
  status=$(jq -r '.status // "UNKNOWN"' <<<"${CLUSTER_JSON}")
  health=$(jq -r '.health_status // "UNKNOWN"' <<<"${CLUSTER_JSON}")
  reason=$(jq -r '.status_reason // ""' <<<"${CLUSTER_JSON}")
  updated=$(jq -r '.updated_at // ""' <<<"${CLUSTER_JSON}")
  worker_count=$(jq -r '(.node_addresses // []) | length' <<<"${CLUSTER_JSON}")
  log::info "status=${status} health=${health} updated=${updated} reason=${reason:-none}"

  case "${status}" in
    CREATE_COMPLETE|UPDATE_COMPLETE)
      if [[ "${health}" == HEALTHY ]]; then
        log::success "Cluster reached ${status} with health ${health}"
        exit 0
      fi
      ;;
    *FAILED*)
      log::die "Cluster entered failed state: ${status}"
      ;;
  esac
  elapsed=$((TIMEOUT - (deadline - SECONDS)))
  if [[ "${diagnosed}" == false && ${elapsed} -ge ${DIAG_AFTER} && ${worker_count} -eq 0 ]]; then
    log::warn "No workers after ${elapsed}s; capturing a redacted support bundle without changing the cluster"
    bash "${REPO_ROOT}/scripts/magnum/diagnose.sh" "${CLUSTER_ID}" >/dev/null
    diagnosed=true
  fi
  sleep "${INTERVAL}"
done

log::die "Timed out after ${TIMEOUT}s waiting for a complete, HEALTHY cluster. Do not retry create; use magnum-diagnose."
