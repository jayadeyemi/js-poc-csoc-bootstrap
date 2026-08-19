#!/usr/bin/env bash
# Credential resolution and non-secret metadata validation helpers.
set -euo pipefail

credentials::magnum_file() {
  if [[ -n "${MAGNUM_CLOUDS_YAML:-}" ]]; then
    printf '%s\n' "${MAGNUM_CLOUDS_YAML}"
  else
    printf '%s/credentials/magnum-clouds.yaml\n' "${REPO_ROOT}"
  fi
}

credentials::runtime_file() {
  if [[ -n "${RUNTIME_CLOUDS_YAML:-}" ]]; then
    printf '%s\n' "${RUNTIME_CLOUDS_YAML}"
  else
    printf '%s/credentials/runtime-clouds.yaml\n' "${REPO_ROOT}"
  fi
}

credentials::require_private_file() {
  local file=$1 label=$2 mode mode_value
  [[ -f "${file}" ]] || log::die "${label} credential file not found: ${file}"
  mode=$(stat -c '%a' "${file}")
  mode_value=$((8#${mode}))
  (( (mode_value & 077) == 0 )) \
    || log::die "${label} credential file must not be group/world accessible: ${file} (mode ${mode})"
}

credentials::configure_magnum() {
  local file
  file=$(credentials::magnum_file)
  credentials::require_private_file "${file}" Magnum
  export OS_CLIENT_CONFIG_FILE="${file}"
  export OS_CLOUD="${OS_CLOUD:-openstack}"
}

# Print only non-secret application credential metadata as JSON.
credentials::metadata() {
  local file=$1 cloud=$2 config_json auth_type credential_id token_json app_json
  config_json=$(OS_CLIENT_CONFIG_FILE="${file}" OS_CLOUD="${cloud}" \
    openstack configuration show -f json)
  auth_type=$(jq -r '.auth_type // ""' <<<"${config_json}")
  [[ "${auth_type}" == *applicationcredential* ]] \
    || log::die "Cloud '${cloud}' in ${file} must use application-credential authentication"
  credential_id=$(jq -r '."auth.application_credential_id" // ""' <<<"${config_json}")
  [[ -n "${credential_id}" ]] \
    || log::die "Cloud '${cloud}' in ${file} has no application credential ID"
  token_json=$(OS_CLIENT_CONFIG_FILE="${file}" OS_CLOUD="${cloud}" \
    openstack token issue -f json) \
    || log::die "OpenStack authentication failed for ${file}"
  app_json=$(OS_CLIENT_CONFIG_FILE="${file}" OS_CLOUD="${cloud}" \
    openstack application credential show "${credential_id}" -f json) \
    || log::die "Unable to inspect application credential for ${file}"
  jq -n \
    --arg id "${credential_id}" \
    --arg project_id "$(jq -r '.project_id // ."Project ID" // ""' <<<"${token_json}")" \
    --arg app_project_id "$(jq -r '.project_id // ."Project ID" // ""' <<<"${app_json}")" \
    --arg unrestricted "$(jq -r '.unrestricted // .Unrestricted // false' <<<"${app_json}")" \
    --arg expires_at "$(jq -r '.expires_at // ."Expires At" // ""' <<<"${app_json}")" \
    '{id:$id,project_id:$project_id,app_project_id:$app_project_id,unrestricted:($unrestricted == "true"),expires_at:$expires_at}'
}

credentials::require_unexpired() {
  local metadata=$1 label=$2 expires_at now_epoch expires_epoch
  expires_at=$(jq -r '.expires_at' <<<"${metadata}")
  [[ -n "${expires_at}" && "${expires_at}" != null && "${expires_at}" != None ]] \
    || log::die "${label} application credential must have an expiration"
  now_epoch=$(date -u +%s)
  expires_epoch=$(date -u -d "${expires_at}" +%s 2>/dev/null) \
    || log::die "${label} credential has an invalid expiration: ${expires_at}"
  (( expires_epoch > now_epoch )) \
    || log::die "${label} application credential expired at ${expires_at}"
}
