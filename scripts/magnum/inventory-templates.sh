#!/usr/bin/env bash
# Save a read-only, timestamped inventory of every visible Magnum template.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"
source "${REPO_ROOT}/scripts/lib/openstack.sh"

command -v jq >/dev/null 2>&1 || log::die "jq is required"

OS_CLOUD="${OS_CLOUD:-openstack}"
SNAPSHOT_ID="${SNAPSHOT_ID:-$(date -u +'%Y-%m-%dT%H%M%SZ')}"
OUTPUT_ROOT="${MAGNUM_TEMPLATE_INVENTORY_DIR:-${REPO_ROOT}/iac/magnum/templates/snapshots}"
OUTPUT_DIR="${OUTPUT_ROOT}/${SNAPSHOT_ID}"

[[ "${SNAPSHOT_ID}" =~ ^[A-Za-z0-9._-]+$ ]] \
  || log::die "SNAPSHOT_ID may contain only letters, numbers, dots, underscores, and hyphens"
[[ ! -e "${OUTPUT_DIR}" ]] \
  || log::die "Snapshot already exists: ${OUTPUT_DIR}"

log::info "Checking OpenStack authentication for cloud '${OS_CLOUD}'"
os::auth_check

mkdir -p "${OUTPUT_ROOT}"
STAGING_DIR="$(mktemp -d "${OUTPUT_ROOT}/.templates.XXXXXX")"
cleanup() {
  rm -rf -- "${STAGING_DIR}"
}
trap cleanup EXIT

mapfile -t TEMPLATE_IDS < <(
  openstack coe cluster template list -f value -c uuid | LC_ALL=C sort
)
(( ${#TEMPLATE_IDS[@]} > 0 )) || log::die "No visible Magnum templates found"

for template_id in "${TEMPLATE_IDS[@]}"; do
  [[ "${template_id}" =~ ^[0-9a-fA-F-]{36}$ ]] \
    || log::die "Unexpected template UUID returned by Magnum: ${template_id}"
  log::info "Recording template ${template_id}"
  openstack coe cluster template show "${template_id}" -f json \
    | jq --sort-keys . >"${STAGING_DIR}/${template_id}.json"
done

CAPTURED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
PROJECT_ID="$(openstack token issue -f value -c project_id)"

jq -s \
  --arg captured_at "${CAPTURED_AT}" \
  --arg cloud "${OS_CLOUD}" \
  --arg project_id "${PROJECT_ID}" \
  '{
    captured_at: $captured_at,
    cloud: $cloud,
    project_id: $project_id,
    count: length,
    public_count: (map(select(.public == true)) | length),
    project_private_count: (map(select(.public == false and .project_id == $project_id)) | length),
    templates: (sort_by(.name, .uuid) | map({
      uuid,
      name,
      public,
      hidden,
      project_id,
      image_id,
      coe,
      created_at
    }))
  }' "${STAGING_DIR}"/*.json >"${STAGING_DIR}/index.json"

mv -- "${STAGING_DIR}" "${OUTPUT_DIR}"
trap - EXIT

log::success "Saved ${#TEMPLATE_IDS[@]} Magnum templates to ${OUTPUT_DIR}"
