#!/usr/bin/env bash
# Capture a redacted, read-only Magnum support bundle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/openstack.bash"
source "${REPO_ROOT}/scripts/lib/credentials.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
csoc::load_profile "${REPO_ROOT}"

STATE_FILE="${MAGNUM_STATE_FILE:-${REPO_ROOT}/.state/magnum-cluster.json}"
credentials::configure_magnum
OWNED_ID=$(os::owned_cluster_id "${STATE_FILE}")
OWNED_NAME=$(jq -er '.cluster_name' "${STATE_FILE}") \
  || log::die "Ownership state has no cluster name: ${STATE_FILE}"
LEGACY_NAME="csoc-${CSOC_PROFILE}"
[[ "${OWNED_NAME}" == "${MAGNUM_CLUSTER_NAME}" || "${OWNED_NAME}" == "${LEGACY_NAME}" ]] \
  || log::die "Ownership state name ${OWNED_NAME} is neither ${MAGNUM_CLUSTER_NAME} nor permitted legacy ${LEGACY_NAME}"
CLUSTER_ID="${1:-${OWNED_ID}}"
[[ "${CLUSTER_ID}" == "${OWNED_ID}" ]] \
  || log::die "Diagnostic UUID does not match bootstrap ownership state"
OUTPUT_DIR="${MAGNUM_DIAGNOSTIC_DIR:-${REPO_ROOT}/.state/diagnostics/$(date -u +'%Y%m%dT%H%M%SZ')}"
mkdir -p "${OUTPUT_DIR}"
chmod 700 "${OUTPUT_DIR}"

CLUSTER_JSON=$(openstack coe cluster show "${CLUSTER_ID}" -f json)
[[ $(jq -r '.name' <<<"${CLUSTER_JSON}") == "${OWNED_NAME}" ]] \
  || log::die "Diagnostic UUID name no longer matches ownership state"
jq '{uuid,name,status,health_status,status_reason,stack_id,created_at,updated_at,api_address,node_addresses,master_addresses,labels,node_count,master_count,master_flavor_id,flavor_id}' \
  <<<"${CLUSTER_JSON}" >"${OUTPUT_DIR}/cluster.json"
STACK_ID=$(jq -r '.stack_id // ""' <<<"${CLUSTER_JSON}")
openstack server list -f json \
  | jq --arg stack "${STACK_ID}" '[.[] | select((.Name // .name // "") | contains($stack)) | {id:(.ID // .id),name:(.Name // .name),status:(.Status // .status),networks:(.Networks // .networks)}]' \
  >"${OUTPUT_DIR}/servers.json"
openstack loadbalancer list -f json \
  | jq --arg stack "${STACK_ID}" '[.[] | select((.name // .Name // "") | contains($stack)) | {id:(.id // .ID),name:(.name // .Name),provisioning_status:(.provisioning_status // ."Provisioning Status"),operating_status:(.operating_status // ."Operating Status")}]' \
  >"${OUTPUT_DIR}/loadbalancers.json"
openstack coe nodegroup list "${CLUSTER_ID}" -f json >"${OUTPUT_DIR}/nodegroups.json"
chmod 600 "${OUTPUT_DIR}"/*.json
log::success "Redacted diagnostic bundle: ${OUTPUT_DIR}"
printf '%s\n' "${OUTPUT_DIR}"
