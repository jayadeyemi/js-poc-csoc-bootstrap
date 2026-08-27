#!/usr/bin/env bash
# Create an expiring application credential without emitting its secret.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"

SOURCE_CLOUDS=${SOURCE_CLOUDS:-}
OUTPUT_CLOUDS=${OUTPUT_CLOUDS:-}
CREDENTIAL_NAME=${CREDENTIAL_NAME:-}
CREDENTIAL_POLICY=${CREDENTIAL_POLICY:-restricted}
CREDENTIAL_EXPIRES_AT=${CREDENTIAL_EXPIRES_AT:-}
IMAGE_NAME=${JETSTREAM_IMAGE_NAME:-jetstream2-mgmt}
IMAGE_TAG=${JETSTREAM_IMAGE_TAG:-latest}

[[ -n "${SOURCE_CLOUDS}" && -f "${SOURCE_CLOUDS}" ]] \
  || log::die "SOURCE_CLOUDS must name an existing seed clouds.yaml"
[[ -n "${OUTPUT_CLOUDS}" ]] \
  || log::die "OUTPUT_CLOUDS is required"
[[ -n "${CREDENTIAL_NAME}" ]] \
  || log::die "CREDENTIAL_NAME is required"
[[ "${CREDENTIAL_POLICY}" == restricted || "${CREDENTIAL_POLICY}" == unrestricted ]] \
  || log::die "CREDENTIAL_POLICY must be restricted or unrestricted"
[[ -n "${CREDENTIAL_EXPIRES_AT}" ]] \
  || log::die "CREDENTIAL_EXPIRES_AT is required"
date -u -d "${CREDENTIAL_EXPIRES_AT}" +%s >/dev/null 2>&1 \
  || log::die "CREDENTIAL_EXPIRES_AT is not a valid timestamp"
(( $(date -u -d "${CREDENTIAL_EXPIRES_AT}" +%s) > $(date -u +%s) )) \
  || log::die "CREDENTIAL_EXPIRES_AT must be in the future"
credential_expires_normalized=$(date -u -d "${CREDENTIAL_EXPIRES_AT}" +%Y-%m-%dT%H:%M:%S)
[[ ! -e "${OUTPUT_CLOUDS}" ]] \
  || log::die "Refusing to overwrite credential file: ${OUTPUT_CLOUDS}"

credentials_mode=$(stat -c '%a' "${SOURCE_CLOUDS}")
credentials_mode_value=$((8#${credentials_mode}))
(( (credentials_mode_value & 077) == 0 )) \
  || log::die "Seed credential must not be group/world accessible (mode ${credentials_mode})"

mkdir -p "$(dirname "${OUTPUT_CLOUDS}")"
chmod 700 "$(dirname "${OUTPUT_CLOUDS}")"
source_path=$(realpath "${SOURCE_CLOUDS}")
output_dir=$(realpath "$(dirname "${OUTPUT_CLOUDS}")")
output_name=$(basename "${OUTPUT_CLOUDS}")

log::info "Creating ${CREDENTIAL_POLICY} application credential ${CREDENTIAL_NAME}"
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --env OS_CLOUD=openstack \
  --env OS_CLIENT_CONFIG_FILE=/run/seed-clouds.yaml \
  --volume "${source_path}:/run/seed-clouds.yaml:ro" \
  --volume "${output_dir}:/output" \
  "${IMAGE_NAME}:${IMAGE_TAG}" \
  bash -c '
    set -euo pipefail
    name=$1
    expires_at=$2
    policy=$3
    output_name=$4
    response=$(mktemp)
    output_tmp="/output/.${output_name}.tmp.$$"
    trap '\''rm -f "${response}" "${output_tmp}"'\'' EXIT
    args=(application credential create "${name}" --expiration "${expires_at}")
    [[ "${policy}" == unrestricted ]] && args+=(--unrestricted)
    openstack "${args[@]}" -f json >"${response}"
    credential_id=$(jq -er ".id // .ID" "${response}")
    credential_secret=$(jq -er ".secret // .Secret" "${response}")
    auth_url=$(openstack configuration show -f json | jq -er ".[\"auth.auth_url\"]")
    umask 077
    jq -n \
      --arg auth_url "${auth_url}" \
      --arg credential_id "${credential_id}" \
      --arg credential_secret "${credential_secret}" \
      "{clouds:{openstack:{auth:{auth_url:\$auth_url,application_credential_id:\$credential_id,application_credential_secret:\$credential_secret},auth_type:\"v3applicationcredential\",region_name:\"IU\",interface:\"public\",identity_api_version:3}}}" \
      >"${output_tmp}"
    chmod 600 "${output_tmp}"
    mv "${output_tmp}" "/output/${output_name}"
  ' _ "${CREDENTIAL_NAME}" "${credential_expires_normalized}" "${CREDENTIAL_POLICY}" "${output_name}"

[[ $(stat -c '%a' "${OUTPUT_CLOUDS}") == 600 ]] \
  || log::die "Generated credential file is not mode 600"
log::success "Created private credential file: ${OUTPUT_CLOUDS}"
