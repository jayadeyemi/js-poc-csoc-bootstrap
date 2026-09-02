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
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
csoc::load_profile "${REPO_ROOT}"
[[ "${CSOC_FLEET_ENABLED}" == true ]] \
  || log::die "Profile ${CSOC_PROFILE} has no fleet credential boundary"
export KUBECONFIG="${KUBECONFIG:-${MAGNUM_KUBECONFIG_DIR}/config}"

usage() {
  printf 'Usage: %s [--all | ACCOUNT]\n' "$0" >&2
  exit 64
}

if [[ -d /run/csoc-credentials/accounts ]]; then
  DEFAULT_ACCOUNTS_DIR=/run/csoc-credentials/accounts
else
  DEFAULT_ACCOUNTS_DIR="${REPO_ROOT}/scripts/host/credentials/accounts"
fi
ACCOUNTS_DIR="${RUNTIME_CREDENTIALS_DIR:-${DEFAULT_ACCOUNTS_DIR}}"
OS_CLOUD="${OS_CLOUD:-openstack}"

declare -a accounts=()
case "${1:-test-poc}" in
  --all)
    while IFS= read -r directory; do accounts+=("$(basename "${directory}")"); done \
      < <(find "${ACCOUNTS_DIR}" -mindepth 1 -maxdepth 1 -type d -print | sort)
    ;;
  -*) usage ;;
  *) (( $# <= 1 )) || usage; accounts+=("${1:-test-poc}") ;;
esac
(( ${#accounts[@]} > 0 )) || log::die "No account credential directories found in ${ACCOUNTS_DIR}"
command -v yq >/dev/null 2>&1 || log::die "Required command not found: yq"

TRUSTED_FLEET_ROOT=
if [[ "${CSOC_TEST_LOCAL_FLEET_SOURCE:-false}" == true ]]; then
  TRUSTED_FLEET_ROOT="${FLEET_ROOT}"
else
  command -v git >/dev/null 2>&1 || log::die "Required command not found: git"
  [[ -d "${FLEET_ROOT}/.git" ]] || log::die "Fleet Git repository not found: ${FLEET_ROOT}"
  TRUSTED_FLEET_ROOT=$(mktemp -d)
  cleanup_trusted_fleet() { rm -rf -- "${TRUSTED_FLEET_ROOT}"; }
  trap cleanup_trusted_fleet EXIT
  git -C "${FLEET_ROOT}" fetch --quiet origin \
    "+refs/heads/${CSOC_FLEET_REVISION}:refs/remotes/origin/${CSOC_FLEET_REVISION}" \
    || log::die "Configured fleet branch is unavailable: ${CSOC_FLEET_REVISION}"
  git -C "${FLEET_ROOT}" archive "refs/remotes/origin/${CSOC_FLEET_REVISION}" \
    | tar -x -C "${TRUSTED_FLEET_ROOT}"
fi

load_identity() {
  local account=$1 identity_file=$2 clouds_file=$3 project_id=$4 credential_json=$5
  local identity cloud_name namespace magnum_file magnum_credential_id
  local auth_url credential_id credential_secret region interface
  local work_dir cloud_conf workload_manifest

  identity=$(yq -er '.metadata.name' "${identity_file}")
  [[ "${identity}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || log::die "Invalid identity name in ${identity_file}: ${identity}"
  cloud_name=openstack
  [[ "${OS_CLOUD}" == openstack ]] \
    || log::die "The standardized OpenStack cloud key is 'openstack', not '${OS_CLOUD}'"

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
    csoc.js2.org/managed=true csoc.js2.org/openstack-credentials=allowed \
    "csoc.js2.org/identity=${identity}" "csoc.js2.org/account=${account}" \
    "csoc.js2.org/openstack-project-id=${project_id}" >/dev/null

  log::step 2 "Creating/updating CAPO and ORC secret for '${identity}'"
  k8s::ensure_secret_from_file "${identity}-cloud-config" "${namespace}" clouds.yaml "${clouds_file}"

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
  printf '%s\n' '[Global]' "auth-url=${auth_url}" \
    "application-credential-id=${credential_id}" \
    "application-credential-secret=${credential_secret}" \
    "region=${region}" "os-endpoint-type=${interface}" 'tls-insecure=false' >"${cloud_conf}"
  chmod 600 "${cloud_conf}"
  kubectl create secret generic cloud-config --namespace kube-system \
    --from-file="cloud.conf=${cloud_conf}" --dry-run=client -o yaml >"${workload_manifest}"
  chmod 600 "${workload_manifest}"
  kubectl create secret generic "${identity}-workload-cloud-config" \
    --namespace "${namespace}" --type addons.cluster.x-k8s.io/resource-set \
    --from-file="cloud-config.yaml=${workload_manifest}" --dry-run=client -o yaml \
    | kubectl apply --server-side -f - >/dev/null
  rm -rf -- "${work_dir}"
  log::success "Runtime secrets for '${identity}' are up-to-date."
}

load_account() {
  local account=$1 clouds_file project_id= credential_json candidate candidate_project
  local -a identity_files=()
  [[ "${account}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || log::die "Invalid account name: ${account}"
  clouds_file="${ACCOUNTS_DIR}/${account}/clouds.yaml"
  credentials::require_private_file "${clouds_file}" "${account}" runtime

  while IFS= read -r candidate; do
    if ACCOUNT_NAME="${account}" yq -e '
        select(
          (.kind == "ImmutableSpokeConfig" and .metadata.labels."csoc.js2.org/account" == strenv(ACCOUNT_NAME)) or
          (.kind == "SpokeAccount" and .apiVersion == "infra.csoc.js2.org/v1alpha1" and .metadata.name == strenv(ACCOUNT_NAME))
        )' "${candidate}" >/dev/null 2>&1; then
      identity_files+=("${candidate}")
    fi
  done < <(find "${TRUSTED_FLEET_ROOT}/${CSOC_FLEET_PATH}/accounts" -type f \
    \( -name identity-config.yaml -o -name spoke-account.yaml \) | sort)
  (( ${#identity_files[@]} > 0 )) \
    || log::die "Trusted legacy identity or v2 SpokeAccount not found for account ${account} in ${CSOC_FLEET_PATH}"

  for candidate in "${identity_files[@]}"; do
    candidate_project=$(yq -er '.spec.projectID' "${candidate}") \
      || log::die "Missing trusted project ID in ${candidate}"
    [[ "${candidate_project}" =~ ^[0-9a-fA-F]{32}$ ]] \
      || log::die "Invalid trusted OpenStack project ID in ${candidate}"
    if [[ -z "${project_id}" ]]; then project_id=${candidate_project}; else
      [[ "${candidate_project}" == "${project_id}" ]] \
        || log::die "Account ${account} spans multiple OpenStack projects"
    fi
  done

  credential_json=$(credentials::metadata "${clouds_file}" openstack)
  credentials::require_unexpired "${credential_json}" "${account}" runtime
  [[ $(jq -r '.project_id' <<<"${credential_json}") == "${project_id}" \
     && $(jq -r '.app_project_id' <<<"${credential_json}") == "${project_id}" \
     && $(jq -r '.unrestricted' <<<"${credential_json}") == false ]] \
    || log::die "Runtime credential for ${account} must be restricted and scoped only to ${project_id}"

  for candidate in "${identity_files[@]}"; do
    load_identity "${account}" "${candidate}" "${clouds_file}" "${project_id}" "${credential_json}"
  done
}

for account in "${accounts[@]}"; do load_account "${account}"; done
