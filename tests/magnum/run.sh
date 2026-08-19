#!/usr/bin/env bash
# Local fake-CLI regression suite for the Magnum lifecycle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/credentials" "${TEST_ROOT}/state" "${TEST_ROOT}/home/.kube"
ln -s "${SCRIPT_DIR}/fake-openstack.sh" "${TEST_ROOT}/bin/openstack"
ln -s "${SCRIPT_DIR}/fake-kubectl.sh" "${TEST_ROOT}/bin/kubectl"
printf 'clouds: {}\n' >"${TEST_ROOT}/credentials/magnum-clouds.yaml"
printf 'clouds: {}\n' >"${TEST_ROOT}/credentials/runtime-clouds.yaml"
chmod 600 "${TEST_ROOT}/credentials"/*.yaml

export PATH="${TEST_ROOT}/bin:${PATH}"
export HOME="${TEST_ROOT}/home"
export MAGNUM_CLOUDS_YAML="${TEST_ROOT}/credentials/magnum-clouds.yaml"
export RUNTIME_CLOUDS_YAML="${TEST_ROOT}/credentials/runtime-clouds.yaml"
export MAGNUM_STATE_FILE="${TEST_ROOT}/state/magnum-cluster.json"
export MAGNUM_KUBECONFIG_DIR="${TEST_ROOT}/home/.kube"
export FAKE_CREATE_LOG="${TEST_ROOT}/create.log"
export FAKE_CONFIG_LOG="${TEST_ROOT}/config.log"
export FAKE_DELETE_LOG="${TEST_ROOT}/delete.log"

pass=0
fail=0
expect_pass() {
  local name=$1; shift
  if "$@" >"${TEST_ROOT}/stdout" 2>"${TEST_ROOT}/stderr"; then
    printf 'ok - %s\n' "${name}"
    ((pass += 1))
  else
    printf 'not ok - %s\n' "${name}"
    sed -n '1,80p' "${TEST_ROOT}/stderr"
    ((fail += 1))
  fi
}
expect_fail() {
  local name=$1; shift
  if "$@" >"${TEST_ROOT}/stdout" 2>"${TEST_ROOT}/stderr"; then
    printf 'not ok - %s (unexpected success)\n' "${name}"
    ((fail += 1))
  else
    printf 'ok - %s\n' "${name}"
    ((pass += 1))
  fi
}

expect_pass "preflight accepts separated credentials and exact infrastructure" \
  bash "${REPO_ROOT}/scripts/magnum/preflight.sh"
FAKE_MAGNUM_UNRESTRICTED=false expect_fail "preflight rejects restricted Magnum credential" \
  bash "${REPO_ROOT}/scripts/magnum/preflight.sh"
FAKE_RUNTIME_UNRESTRICTED=true expect_fail "preflight rejects unrestricted runtime credential" \
  bash "${REPO_ROOT}/scripts/magnum/preflight.sh"
FAKE_MAGNUM_EXPIRES_AT=2020-01-01T00:00:00Z expect_fail "preflight rejects expired credentials" \
  bash "${REPO_ROOT}/scripts/magnum/preflight.sh"
FAKE_PROJECT_ID=wrong expect_fail "preflight rejects wrong project" \
  bash "${REPO_ROOT}/scripts/magnum/preflight.sh"
FAKE_IMAGE_ID=wrong expect_fail "preflight rejects wrong image UUID" \
  bash "${REPO_ROOT}/scripts/magnum/preflight.sh"
FAKE_FIXED_NETWORK_ID=wrong expect_fail "preflight rejects wrong fixed network UUID" \
  bash "${REPO_ROOT}/scripts/magnum/preflight.sh"
FAKE_SUBNET_NETWORK_ID=wrong expect_fail "preflight rejects wrong subnet relationship" \
  bash "${REPO_ROOT}/scripts/magnum/preflight.sh"
FAKE_MAX_INSTANCES=1 expect_fail "preflight rejects insufficient compute quota" \
  bash "${REPO_ROOT}/scripts/magnum/preflight.sh"
FAKE_VOLUME_SIZE=49900 expect_fail "preflight rejects less than 200 GiB volume headroom" \
  bash "${REPO_ROOT}/scripts/magnum/preflight.sh"
FAKE_AMBIGUOUS=true expect_fail "preflight rejects ambiguous cluster ownership" \
  bash "${REPO_ROOT}/scripts/magnum/preflight.sh"
MAGNUM_STATE_FILE=/proc/csoc-state/cluster.json expect_fail "preflight rejects unwritable state path" \
  bash "${REPO_ROOT}/scripts/magnum/preflight.sh"

rm -f "${FAKE_CREATE_LOG}" "${MAGNUM_STATE_FILE}"
expect_pass "provision submits the guide-exact create request" \
  bash "${REPO_ROOT}/scripts/magnum/provision.sh"
for required in \
  '--cluster-template 284de191-b8ea-4dae-9046-6ab982bd1c3a' \
  '--master-count 1' '--node-count 1' '--master-flavor m3.quad' '--flavor m3.quad' \
  '--fixed-network auto_allocated_network' '--fixed-subnet auto_allocated_subnet_v4' \
  '--floating-ip-enabled' '--master-lb-enabled' '--merge-labels' \
  '--labels boot_volume_size=100' '--labels auto_scaling_enabled=true' \
  '--labels min_node_count=1' '--labels max_node_count=2'; do
  grep -F -- "${required}" "${FAKE_CREATE_LOG}" >/dev/null \
    || { printf 'not ok - create request missing %s\n' "${required}"; ((fail += 1)); }
done
if grep -E -- '(^| )-(f|c)( |$)' "${FAKE_CREATE_LOG}" >/dev/null; then
  printf 'not ok - create request contains unsupported formatter flags\n'
  ((fail += 1))
else
  printf 'ok - create request omits unsupported formatter flags\n'
  ((pass += 1))
fi

printf '%s\n' \
  '{"status":"CREATE_IN_PROGRESS","health_status":"UNHEALTHY","status_reason":null,"updated_at":"1","node_addresses":["10.0.0.2"]}' \
  '{"status":"CREATE_COMPLETE","health_status":"HEALTHY","status_reason":null,"updated_at":"2","node_addresses":["10.0.0.2"]}' \
  >"${TEST_ROOT}/wait-sequence"
export FAKE_WAIT_SEQUENCE="${TEST_ROOT}/wait-sequence"
MAGNUM_WAIT_INTERVAL=0 MAGNUM_WAIT_TIMEOUT=5 expect_pass "wait requires complete and HEALTHY" \
  bash "${REPO_ROOT}/scripts/magnum/wait.sh"
unset FAKE_WAIT_SEQUENCE
FAKE_CLUSTER_STATUS=CREATE_IN_PROGRESS FAKE_CLUSTER_HEALTH=UNHEALTHY \
  MAGNUM_WAIT_INTERVAL=0 MAGNUM_WAIT_TIMEOUT=1 MAGNUM_NO_WORKER_DIAG_AFTER=99 \
  expect_fail "wait enforces a wall-clock timeout" bash "${REPO_ROOT}/scripts/magnum/wait.sh"

FAKE_CLUSTER_EXISTS=true expect_pass "kubeconfig uses certificate authentication" \
  bash "${REPO_ROOT}/scripts/magnum/kubeconfig.sh"
grep -F -- '--use-certificate' "${FAKE_CONFIG_LOG}" >/dev/null
grep -F -- '--output-certs' "${FAKE_CONFIG_LOG}" >/dev/null
FAKE_CLUSTER_EXISTS=true expect_pass "readiness verifies nodes, DNS, roots, and bounds" \
  bash "${REPO_ROOT}/scripts/magnum/verify.sh"
FAKE_CLUSTER_EXISTS=true FAKE_KUBE_UNINITIALIZED=true \
  expect_fail "readiness rejects cloud-provider-uninitialized taints" \
  bash "${REPO_ROOT}/scripts/magnum/verify.sh"

export MAGNUM_DIAGNOSTIC_DIR="${TEST_ROOT}/diagnostics"
FAKE_CLUSTER_EXISTS=true expect_fail "delete rejects a UUID outside ownership state" \
  bash "${REPO_ROOT}/scripts/magnum/delete-owned.sh" wrong-cluster-id
[[ ! -e "${FAKE_DELETE_LOG}" ]] \
  || { printf 'not ok - mismatched UUID submitted a delete\n'; ((fail += 1)); }
FAKE_CLUSTER_EXISTS=true FAKE_CLUSTER_STATUS=DELETE_IN_PROGRESS \
  MAGNUM_DELETE_TIMEOUT=0 expect_fail "delete resumes monitoring without resubmitting" \
  bash "${REPO_ROOT}/scripts/magnum/delete-owned.sh" \
    11111111-2222-3333-4444-555555555555
if [[ -e "${FAKE_DELETE_LOG}" ]]; then
  printf 'not ok - DELETE_IN_PROGRESS was resubmitted\n'
  ((fail += 1))
else
  printf 'ok - DELETE_IN_PROGRESS was not resubmitted\n'
  ((pass += 1))
fi

printf '%s passed; %s failed\n' "${pass}" "${fail}"
(( fail == 0 ))
