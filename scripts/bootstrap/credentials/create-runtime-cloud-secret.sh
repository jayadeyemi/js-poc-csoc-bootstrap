#!/usr/bin/env bash
# Create account-scoped CAPO, ORC, CCM, and CSI secrets without exposing values.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
FLEET_ROOT="${FLEET_ROOT:-${WORKSPACE_ROOT}/js-poc-csoc-fleet}"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/k8s.bash"
source "${REPO_ROOT}/scripts/lib/credentials.bash"

usage() {
  printf 'Usage: %s [--all | IDENTITY]\n' "$0" >&2
  exit 64
}

if [[ -d /run/csoc-credentials/accounts ]]; then
  DEFAULT_ACCOUNTS_DIR=/run/csoc-credentials/accounts
else
  DEFAULT_ACCOUNTS_DIR="${REPO_ROOT}/scripts/host/credentials/accounts"
fi
ACCOUNTS_DIR="${RUNTIME_CREDENTIALS_DIR:-${DEFAULT_ACCOUNTS_DIR}}"
OS_CLOUD="${OS_CLOUD:-openstack}"

declare -a identities=()
case "${1:-test-poc}" in
  --all)
    while IFS= read -r directory; do
      identities+=("$(basename "${directory}")")
    done < <(find "${ACCOUNTS_DIR}" -mindepth 1 -maxdepth 1 -type d -print | sort)
    ;;
  -*) usage ;;
  *)
    (( $# <= 1 )) || usage
    identities+=("${1:-test-poc}")
    ;;
esac
(( ${#identities[@]} > 0 )) || log::die "No account credential directories found in ${ACCOUNTS_DIR}"

command -v yq >/dev/null 2>&1 || log::die "Required command not found: yq"

load_identity() {
  local identity=$1 identity_file clouds_file project_id cloud_name namespace
  local credential_json magnum_file magnum_credential_id
  local auth_url credential_id credential_secret region interface
  local work_dir cloud_conf workload_manifest

  [[ "${identity}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || log::die "Invalid identity name: ${identity}"
  identity_file="${FLEET_ROOT}/accounts/${identity}/identity-config.yaml"
  clouds_file="${ACCOUNTS_DIR}/${identity}/clouds.yaml"
  [[ -f "${identity_file}" ]] \
    || log::die "Trusted SpokeIdentity configuration not found: ${identity_file}"
  credentials::require_private_file "${clouds_file}" "${identity} runtime"

  project_id=$(IDENTITY_NAME="${identity}" yq -er \
    'select(.kind == "ImmutableSpokeConfig" and .metadata.name == strenv(IDENTITY_NAME)) | .spec.projectID' \
    "${identity_file}") \
    || log::die "Missing trusted ImmutableSpokeConfig instance in ${identity_file}"
  [[ "${project_id}" =~ ^[0-9a-fA-F]{32}$ ]] \
    || log::die "Invalid trusted OpenStack project ID in ${identity_file}"
  cloud_name=openstack
  [[ "${OS_CLOUD}" == openstack ]] \
    || log::die "The standardized OpenStack cloud key is 'openstack', not '${OS_CLOUD}'"

  credential_json=$(credentials::metadata "${clouds_file}" "${cloud_name}")
  credentials::require_unexpired "${credential_json}" "${identity} runtime"
  [[ $(jq -r '.project_id' <<<"${credential_json}") == "${project_id}" \
     && $(jq -r '.app_project_id' <<<"${credential_json}") == "${project_id}" \
     && $(jq -r '.unrestricted' <<<"${credential_json}") == false ]] \
    || log::die "Runtime credential for ${identity} must be restricted and scoped only to ${project_id}"

  credential_id=$(jq -r '.id' <<<"${credential_json}")
  magnum_file=$(credentials::magnum_file)
  credentials::require_private_file "${magnum_file}" Magnum
  magnum_credential_id=$(CLOUD_NAME="${cloud_name}" yq -er \
    '.clouds[strenv(CLOUD_NAME)].auth.application_credential_id' "${magnum_file}") \
    || log::die "Magnum cloud must use a separate application credential"
  [[ "${credential_id}" != "${magnum_credential_id}" ]] \
    || log::die "Spoke identity ${identity} must not reuse the CSOC Magnum application credential"

  namespace="spokeclusters-${identity}"
  log::step 1 "Ensuring account namespace '${namespace}'"
  k8s::ensure_namespace "${namespace}"
  kubectl label namespace "${namespace}" --overwrite \
    csoc.js2.org/managed=true \
    csoc.js2.org/openstack-credentials=allowed \
    "csoc.js2.org/identity=${identity}" \
    "csoc.js2.org/openstack-project-id=${project_id}" >/dev/null

  log::step 2 "Creating/updating CAPO and ORC secret for '${identity}'"
  k8s::ensure_secret_from_file \
    "${identity}-cloud-config" \
    "${namespace}" \
    clouds.yaml \
    "${clouds_file}"

  auth_url=$(CLOUD_NAME="${cloud_name}" yq -er '.clouds[strenv(CLOUD_NAME)].auth.auth_url' "${clouds_file}")
  credential_secret=$(CLOUD_NAME="${cloud_name}" yq -er '.clouds[strenv(CLOUD_NAME)].auth.application_credential_secret' "${clouds_file}")
  region=$(CLOUD_NAME="${cloud_name}" yq -er '.clouds[strenv(CLOUD_NAME)].region_name' "${clouds_file}")
  interface=$(CLOUD_NAME="${cloud_name}" yq -er '.clouds[strenv(CLOUD_NAME)].interface // "public"' "${clouds_file}")
  for value in "${auth_url}" "${credential_id}" "${credential_secret}" "${region}" "${interface}"; do
    [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] \
      || log::die "OpenStack cloud values must not contain newlines"
  done

  log::step 3 "Creating/updating workload cloud-config for '${identity}'"
  work_dir=$(mktemp -d)
  chmod 700 "${work_dir}"
  cloud_conf="${work_dir}/cloud.conf"
  workload_manifest="${work_dir}/cloud-config.yaml"
  printf '%s\n' \
    '[Global]' \
    "auth-url=${auth_url}" \
    "application-credential-id=${credential_id}" \
    "application-credential-secret=${credential_secret}" \
    "region=${region}" \
    "os-endpoint-type=${interface}" \
    'tls-insecure=false' >"${cloud_conf}"
  chmod 600 "${cloud_conf}"
  kubectl create secret generic cloud-config \
    --namespace kube-system \
    --from-file="cloud.conf=${cloud_conf}" \
    --dry-run=client -o yaml >"${workload_manifest}"
  chmod 600 "${workload_manifest}"
  kubectl create secret generic "${identity}-workload-cloud-config" \
    --namespace "${namespace}" \
    --type addons.cluster.x-k8s.io/resource-set \
    --from-file="cloud-config.yaml=${workload_manifest}" \
    --dry-run=client -o yaml \
    | kubectl apply --server-side -f - >/dev/null
  rm -rf -- "${work_dir}"
  log::success "Runtime secrets for '${identity}' are up-to-date."
}

for identity in "${identities[@]}"; do
  load_identity "${identity}"
done
