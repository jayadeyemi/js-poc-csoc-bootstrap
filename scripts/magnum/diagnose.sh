#!/usr/bin/env bash
# Capture a redacted, read-only Magnum support bundle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"
source "${REPO_ROOT}/scripts/lib/openstack.sh"
source "${REPO_ROOT}/scripts/lib/credentials.sh"
source "${REPO_ROOT}/iac/magnum/cluster.env"

STATE_FILE="${MAGNUM_STATE_FILE:-${REPO_ROOT}/.state/magnum-cluster.json}"
credentials::configure_magnum
CLUSTER_ID="${1:-$(os::verify_owned_cluster "${STATE_FILE}" "${MAGNUM_CLUSTER_NAME}")}"
[[ "${CLUSTER_ID}" == "$(os::verify_owned_cluster "${STATE_FILE}" "${MAGNUM_CLUSTER_NAME}")" ]] \
  || log::die "Diagnostic UUID does not match bootstrap ownership state"
OUTPUT_DIR="${MAGNUM_DIAGNOSTIC_DIR:-${REPO_ROOT}/.state/diagnostics/$(date -u +'%Y%m%dT%H%M%SZ')}"
mkdir -p "${OUTPUT_DIR}"
chmod 700 "${OUTPUT_DIR}"

CLUSTER_JSON=$(openstack coe cluster show "${CLUSTER_ID}" -f json)
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
