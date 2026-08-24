#!/usr/bin/env bash
# Idempotently create CAPO and workload-addon secrets from clouds.yaml.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/k8s.bash"
source "${REPO_ROOT}/scripts/lib/credentials.bash"
source "${REPO_ROOT}/iac/magnum/cluster.env"

# Resolve only the restricted runtime credential.
if [[ -n "${RUNTIME_CLOUDS_YAML:-}" ]]; then
  RESOLVED_CLOUDS_YAML="${RUNTIME_CLOUDS_YAML}"
elif [[ -f "${REPO_ROOT}/credentials/runtime-clouds.yaml" ]]; then
  RESOLVED_CLOUDS_YAML="${REPO_ROOT}/credentials/runtime-clouds.yaml"
else
  RESOLVED_CLOUDS_YAML="${HOME}/.config/openstack/runtime-clouds.yaml"
fi
[[ -f "${RESOLVED_CLOUDS_YAML}" ]] \
  || log::die "Restricted runtime clouds.yaml not found at ${RESOLVED_CLOUDS_YAML}. Set RUNTIME_CLOUDS_YAML."
credentials::require_private_file "${RESOLVED_CLOUDS_YAML}" Runtime
RUNTIME_CREDENTIAL_JSON=$(credentials::metadata "${RESOLVED_CLOUDS_YAML}" "${OS_CLOUD:-openstack}")
credentials::require_unexpired "${RUNTIME_CREDENTIAL_JSON}" Runtime
[[ $(jq -r '.project_id' <<<"${RUNTIME_CREDENTIAL_JSON}") == "${MAGNUM_PROJECT_ID}" \
   && $(jq -r '.unrestricted' <<<"${RUNTIME_CREDENTIAL_JSON}") == false ]] \
  || log::die "Runtime credential must be restricted and scoped to ${MAGNUM_PROJECT_ID}"

SECRET_NAMESPACE="${CAPO_SECRET_NAMESPACE:-capo-system}"
WORKLOAD_SECRET_NAMESPACE="${WORKLOAD_SECRET_NAMESPACE:-spokeclusters}"
OS_CLOUD="${OS_CLOUD:-openstack}"

command -v yq >/dev/null 2>&1 || log::die "Required command not found: yq"

cloud_value() {
  local expression=$1
  CLOUD_NAME="${OS_CLOUD}" yq -er "${expression}" "${RESOLVED_CLOUDS_YAML}" \
    || log::die "Missing required '${OS_CLOUD}' value in ${RESOLVED_CLOUDS_YAML}"
}

AUTH_URL=$(cloud_value '.clouds[strenv(CLOUD_NAME)].auth.auth_url')
APPLICATION_CREDENTIAL_ID=$(cloud_value '.clouds[strenv(CLOUD_NAME)].auth.application_credential_id')
APPLICATION_CREDENTIAL_SECRET=$(cloud_value '.clouds[strenv(CLOUD_NAME)].auth.application_credential_secret')
REGION=$(cloud_value '.clouds[strenv(CLOUD_NAME)].region_name')
INTERFACE=$(cloud_value '.clouds[strenv(CLOUD_NAME)].interface // "public"')

for value in "${AUTH_URL}" "${APPLICATION_CREDENTIAL_ID}" \
  "${APPLICATION_CREDENTIAL_SECRET}" "${REGION}" "${INTERFACE}"; do
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] \
    || log::die "OpenStack cloud values must not contain newlines"
done

log::step 1 "Ensuring namespace '${SECRET_NAMESPACE}'"
k8s::ensure_namespace "${SECRET_NAMESPACE}"

log::step 2 "Creating/updating secret 'openstack-cloud-config' in ${SECRET_NAMESPACE}"
k8s::ensure_secret_from_file \
  openstack-cloud-config \
  "${SECRET_NAMESPACE}" \
  clouds.yaml \
  "${RESOLVED_CLOUDS_YAML}"

log::step 3 "Creating/updating workload cloud-config resource set"
k8s::ensure_namespace "${WORKLOAD_SECRET_NAMESPACE}"
work_dir=$(mktemp -d)
chmod 700 "${work_dir}"
trap 'rm -rf -- "${work_dir}"' EXIT
cloud_conf="${work_dir}/cloud.conf"
workload_manifest="${work_dir}/cloud-config.yaml"

printf '%s\n' \
  '[Global]' \
  "auth-url=${AUTH_URL}" \
  "application-credential-id=${APPLICATION_CREDENTIAL_ID}" \
  "application-credential-secret=${APPLICATION_CREDENTIAL_SECRET}" \
  "region=${REGION}" \
  "os-endpoint-type=${INTERFACE}" \
  'tls-insecure=false' >"${cloud_conf}"
chmod 600 "${cloud_conf}"

kubectl create secret generic cloud-config \
  --namespace kube-system \
  --from-file="cloud.conf=${cloud_conf}" \
  --dry-run=client -o yaml >"${workload_manifest}"
chmod 600 "${workload_manifest}"

kubectl create secret generic openstack-workload-cloud-config \
  --namespace "${WORKLOAD_SECRET_NAMESPACE}" \
  --type addons.cluster.x-k8s.io/resource-set \
  --from-file="cloud-config.yaml=${workload_manifest}" \
  --dry-run=client -o yaml \
  | kubectl apply --server-side -f - >/dev/null

log::success "CAPO and workload OpenStack secrets are up-to-date."
