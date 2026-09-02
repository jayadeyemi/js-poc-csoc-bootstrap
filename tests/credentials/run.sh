#!/usr/bin/env bash
# Regression test for account isolation, project verification, and idempotent secret loading.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/accounts/account-a" \
  "${TEST_ROOT}/accounts/account-b" \
  "${TEST_ROOT}/accounts/account-v2" \
  "${TEST_ROOT}/fleet/environments/staging/accounts/account-a/hello/dev" \
  "${TEST_ROOT}/fleet/environments/staging/accounts/account-b/hello/dev" \
  "${TEST_ROOT}/fleet/environments/staging/accounts/account-v2/shared/dev" \
  "${TEST_ROOT}/kube-state"
ln -s "${SCRIPT_DIR}/fake-openstack.sh" "${TEST_ROOT}/bin/openstack"
ln -s "${SCRIPT_DIR}/fake-kubectl.sh" "${TEST_ROOT}/bin/kubectl"

write_identity() {
  local identity=$1 project=$2
  printf '%s\n' \
    'apiVersion: csoc.js2.org/v1alpha1' \
    'kind: ImmutableSpokeConfig' \
    'metadata:' \
    "  name: ${identity}" \
    "  labels: {csoc.js2.org/account: ${identity}}" \
    'spec:' \
    "  projectID: ${project}" \
    >"${TEST_ROOT}/fleet/environments/staging/accounts/${identity}/hello/dev/identity-config.yaml"
}

write_cloud() {
  local identity=$1
  printf '%s\n' \
    'clouds:' \
    '  openstack:' \
    '    auth:' \
    '      auth_url: https://openstack.example/v3' \
    "      application_credential_id: ${identity}-id" \
    "      application_credential_secret: ${identity}-never-print" \
    '    region_name: RegionOne' \
    '    interface: public' \
    >"${TEST_ROOT}/accounts/${identity}/clouds.yaml"
  chmod 600 "${TEST_ROOT}/accounts/${identity}/clouds.yaml"
}

write_magnum_cloud() {
  local credential_id=$1
  printf '%s\n' \
    'clouds:' \
    '  openstack:' \
    '    auth:' \
    '      auth_url: https://openstack.example/v3' \
    "      application_credential_id: ${credential_id}" \
    '      application_credential_secret: <MAGNUM_APP_CREDENTIAL_SECRET>' \
    '    region_name: RegionOne' \
    >"${TEST_ROOT}/magnum-clouds.yaml"
  chmod 600 "${TEST_ROOT}/magnum-clouds.yaml"
}

write_identity account-a aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
write_identity account-b bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
printf '%s\n' \
  'apiVersion: infra.csoc.js2.org/v1alpha1' \
  'kind: SpokeAccount' \
  'metadata: {name: account-v2, namespace: spokeclusters-account-v2}' \
  'spec:' \
  '  projectID: cccccccccccccccccccccccccccccccc' \
  >"${TEST_ROOT}/fleet/environments/staging/accounts/account-v2/shared/dev/spoke-account.yaml"
write_cloud account-a
write_cloud account-b
write_cloud account-v2
write_magnum_cloud magnum-id

export PATH="${TEST_ROOT}/bin:${PATH}"
export RUNTIME_CREDENTIALS_DIR="${TEST_ROOT}/accounts"
export FLEET_ROOT="${TEST_ROOT}/fleet"
export MAGNUM_CLOUDS_YAML="${TEST_ROOT}/magnum-clouds.yaml"
export FAKE_KUBECTL_LOG="${TEST_ROOT}/kubectl.log"
export FAKE_KUBECTL_STATE="${TEST_ROOT}/kube-state"
export CSOC_TEST_LOCAL_FLEET_SOURCE=true
unset MAGNUM_CLUSTER_NAME MAGNUM_STATE_FILE MAGNUM_KUBECONFIG_DIR
unset MAGNUM_MASTER_COUNT MAGNUM_MASTER_FLAVOR MAGNUM_NODE_COUNT MAGNUM_WORKER_FLAVOR
unset MAGNUM_MIN_NODE_COUNT MAGNUM_MAX_NODE_COUNT MAGNUM_EXPECTED_INITIAL_NODES
unset MAGNUM_BOOT_VOLUME_SIZE MAGNUM_AUTO_SCALING_ENABLED
unset CSOC_BOOTSTRAP_REVISION CSOC_CATALOG_REVISION CSOC_FLEET_REVISION
export CSOC_PROFILE=staging

run_loader() {
  bash "${REPO_ROOT}/scripts/bootstrap/credentials/create-runtime-cloud-secret.sh" --all \
    >"${TEST_ROOT}/stdout" 2>"${TEST_ROOT}/stderr"
}

run_loader
run_loader

for identity in account-a account-b account-v2; do
  namespace="spokeclusters-${identity}"
  grep -F -- "${identity}-cloud-config --from-file=clouds.yaml=${TEST_ROOT}/accounts/${identity}/clouds.yaml --namespace ${namespace}" \
    "${FAKE_KUBECTL_LOG}" >/dev/null
  grep -F -- "${identity}-workload-cloud-config --namespace ${namespace}" \
    "${FAKE_KUBECTL_LOG}" >/dev/null
  grep -F -- "csoc.js2.org/identity=${identity}" "${FAKE_KUBECTL_LOG}" >/dev/null
done

if rg -q 'account-(a|b)-never-print' "${TEST_ROOT}/stdout" "${TEST_ROOT}/stderr" "${FAKE_KUBECTL_LOG}"; then
  printf 'not ok - credential value was written to output\n' >&2
  exit 1
fi

if FAKE_CREDENTIAL_PROJECT=cccccccccccccccccccccccccccccccc \
    bash "${REPO_ROOT}/scripts/bootstrap/credentials/create-runtime-cloud-secret.sh" account-a \
      >"${TEST_ROOT}/mismatch-stdout" 2>"${TEST_ROOT}/mismatch-stderr"; then
  printf 'not ok - mismatched OpenStack project was accepted\n' >&2
  exit 1
fi

write_magnum_cloud account-a-id
if bash "${REPO_ROOT}/scripts/bootstrap/credentials/create-runtime-cloud-secret.sh" account-a \
    >"${TEST_ROOT}/reused-stdout" 2>"${TEST_ROOT}/reused-stderr"; then
  printf 'not ok - spoke credential reused the Magnum application credential\n' >&2
  exit 1
fi

printf 'ok - legacy and v2 identities load isolated restricted credentials idempotently\n'
printf 'ok - credential output is redacted and project mismatch is rejected\n'
printf 'ok - spoke and Magnum application credential IDs must differ\n'
