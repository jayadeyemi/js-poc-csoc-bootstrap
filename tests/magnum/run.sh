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
export CSOC_PROFILE=dev
export MAGNUM_CLUSTER_NAME=js-csoc-dev
export FAKE_CREATE_LOG="${TEST_ROOT}/create.log"
export FAKE_CONFIG_LOG="${TEST_ROOT}/config.log"
export FAKE_DELETE_LOG="${TEST_ROOT}/delete.log"
export FAKE_NODEGROUP_UPDATE_LOG="${TEST_ROOT}/nodegroup-update.log"
export FAKE_AUTOSCALE_STATE="${TEST_ROOT}/autoscale-state"

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

expect_pass "cluster name supports an isolated environment override" \
  bash -c 'MAGNUM_CLUSTER_NAME=js2-mgmt-cluster-2; export MAGNUM_CLUSTER_NAME; source "$1"; [[ "$MAGNUM_CLUSTER_NAME" == js2-mgmt-cluster-2 ]]' \
  _ "${REPO_ROOT}/iac/magnum/cluster.env"

expect_pass "dev profile isolates v2 graph development and disables fleet" \
  bash -c 'unset MAGNUM_CLUSTER_NAME MAGNUM_STATE_FILE MAGNUM_KUBECONFIG_DIR MAGNUM_MASTER_COUNT MAGNUM_MASTER_FLAVOR MAGNUM_NODE_COUNT MAGNUM_WORKER_FLAVOR MAGNUM_MIN_NODE_COUNT MAGNUM_MAX_NODE_COUNT MAGNUM_EXPECTED_INITIAL_NODES MAGNUM_BOOT_VOLUME_SIZE MAGNUM_AUTO_SCALING_ENABLED CSOC_BOOTSTRAP_REVISION CSOC_CATALOG_REVISION CSOC_FLEET_REVISION; source "$1"; csoc::load_profile "$2"; [[ "$MAGNUM_CLUSTER_NAME" == js-csoc-dev && "$MAGNUM_STATE_FILE" == "$2/.state/csoc/dev/magnum-cluster.json" && "$CSOC_CATALOG_REVISION" == environment/dev && "$CSOC_FLEET_ENABLED" == false && "$CSOC_API_GENERATION" == v2 && "$MAGNUM_BOOT_VOLUME_SIZE" == 20 ]]' \
  _ "${REPO_ROOT}/scripts/lib/csoc-profile.bash" "${REPO_ROOT}"

expect_pass "prod profile freezes an HA control plane and coordinated branch" \
  bash -c 'unset MAGNUM_CLUSTER_NAME MAGNUM_STATE_FILE MAGNUM_KUBECONFIG_DIR MAGNUM_MASTER_COUNT MAGNUM_MASTER_FLAVOR MAGNUM_NODE_COUNT MAGNUM_WORKER_FLAVOR MAGNUM_MIN_NODE_COUNT MAGNUM_MAX_NODE_COUNT MAGNUM_EXPECTED_INITIAL_NODES MAGNUM_BOOT_VOLUME_SIZE MAGNUM_AUTO_SCALING_ENABLED CSOC_BOOTSTRAP_REVISION CSOC_CATALOG_REVISION CSOC_FLEET_REVISION; CSOC_PROFILE=prod; export CSOC_PROFILE; source "$1"; csoc::load_profile "$2"; [[ "$MAGNUM_MASTER_COUNT" == 3 && "$MAGNUM_MASTER_FLAVOR" == m3.small && "$CSOC_CATALOG_REVISION" == environment/prod && "$CSOC_FLEET_ENABLED" == true && "$MAGNUM_BOOT_VOLUME_SIZE" == 20 ]]' \
  _ "${REPO_ROOT}/scripts/lib/csoc-profile.bash" "${REPO_ROOT}"

expect_pass "preflight accepts separated credentials and exact infrastructure" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/preflight.sh"
RUNTIME_CLOUDS_YAML="${TEST_ROOT}/credentials/missing-runtime-clouds.yaml" \
  expect_pass "dev preflight does not require an inactive fleet credential" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/preflight.sh"
FAKE_MAGNUM_UNRESTRICTED=false expect_fail "preflight rejects restricted Magnum credential" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/preflight.sh"
FAKE_RUNTIME_UNRESTRICTED=true expect_fail "preflight rejects unrestricted runtime credential" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/preflight.sh"
FAKE_MAGNUM_EXPIRES_AT=2020-01-01T00:00:00Z expect_fail "preflight rejects expired credentials" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/preflight.sh"
FAKE_PROJECT_ID=wrong expect_fail "preflight rejects wrong project" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/preflight.sh"
FAKE_IMAGE_ID=wrong expect_fail "preflight rejects wrong image UUID" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/preflight.sh"
FAKE_IMAGE_MIN_DISK=21 expect_fail "preflight rejects a boot volume below the image floor" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/preflight.sh"
FAKE_FIXED_NETWORK_ID=wrong expect_fail "preflight rejects wrong fixed network UUID" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/preflight.sh"
FAKE_SUBNET_NETWORK_ID=wrong expect_fail "preflight rejects wrong subnet relationship" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/preflight.sh"
FAKE_MAX_INSTANCES=1 expect_fail "preflight rejects insufficient compute quota" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/preflight.sh"
FAKE_VOLUME_SIZE=49980 expect_fail "preflight rejects less than 40 GiB volume headroom" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/preflight.sh"
FAKE_AMBIGUOUS=true expect_fail "preflight rejects ambiguous cluster ownership" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/preflight.sh"
MAGNUM_STATE_FILE=/proc/csoc-state/cluster.json expect_fail "preflight rejects unwritable state path" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/preflight.sh"
jq -n \
  --arg id legacy-dev-id \
  --arg name csoc-dev \
  --arg template 284de191-b8ea-4dae-9046-6ab982bd1c3a \
  '{cluster_id:$id,cluster_name:$name,template_id:$template}' \
  >"${MAGNUM_STATE_FILE}"
expect_fail "preflight blocks js-csoc-dev while legacy csoc-dev ownership state exists" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/preflight.sh"

rm -f "${FAKE_CREATE_LOG}" "${MAGNUM_STATE_FILE}"
expect_pass "provision submits the guide-exact create request" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/provision.sh"
for required in \
  '--cluster-template 284de191-b8ea-4dae-9046-6ab982bd1c3a' \
  '--master-count 1' '--node-count 1' '--master-flavor m3.small' '--flavor m3.quad' \
  '--fixed-network auto_allocated_network' '--fixed-subnet auto_allocated_subnet_v4' \
  '--floating-ip-enabled' '--master-lb-enabled' '--merge-labels' \
  '--labels boot_volume_size=20' '--labels auto_scaling_enabled=false' \
  '--labels min_node_count=1' '--labels max_node_count=1'; do
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

FAKE_CLUSTER_EXISTS=true expect_pass "CSOC IaC plan reads owned state without mutation" \
  bash "${REPO_ROOT}/scripts/operations/csoc/plan.sh"
expect_fail "CSOC mutable reconcile requires exact cluster-name confirmation" \
  bash "${REPO_ROOT}/scripts/operations/csoc/reconcile-mutable.sh" --confirm wrong-name
expect_fail "CSOC mutable reconcile rejects immutable spec drift" \
  env FAKE_CLUSTER_EXISTS=true MAGNUM_WORKER_FLAVOR=m3.medium \
  bash "${REPO_ROOT}/scripts/operations/csoc/reconcile-mutable.sh" \
    --confirm js-csoc-dev
FAKE_CLUSTER_EXISTS=true expect_pass "CSOC mutable reconcile changes only reviewed worker bounds" \
  bash "${REPO_ROOT}/scripts/operations/csoc/reconcile-mutable.sh" \
    --confirm js-csoc-dev

printf '%s\n' \
  '{"status":"CREATE_IN_PROGRESS","health_status":"UNHEALTHY","status_reason":null,"updated_at":"1","node_addresses":["10.0.0.2"]}' \
  '{"status":"CREATE_COMPLETE","health_status":"HEALTHY","status_reason":null,"updated_at":"2","node_addresses":["10.0.0.2"]}' \
  >"${TEST_ROOT}/wait-sequence"
export FAKE_WAIT_SEQUENCE="${TEST_ROOT}/wait-sequence"
MAGNUM_WAIT_INTERVAL=0 MAGNUM_WAIT_TIMEOUT=5 expect_pass "wait requires complete and HEALTHY" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/wait.sh"
unset FAKE_WAIT_SEQUENCE
FAKE_CLUSTER_STATUS=CREATE_IN_PROGRESS FAKE_CLUSTER_HEALTH=UNHEALTHY \
  MAGNUM_WAIT_INTERVAL=0 MAGNUM_WAIT_TIMEOUT=1 MAGNUM_NO_WORKER_DIAG_AFTER=99 \
  expect_fail "wait enforces a wall-clock timeout" bash "${REPO_ROOT}/scripts/bootstrap/magnum/wait.sh"

FAKE_CLUSTER_EXISTS=true expect_pass "kubeconfig uses certificate authentication" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/kubeconfig.sh"
grep -F -- '--use-certificate' "${FAKE_CONFIG_LOG}" >/dev/null
grep -F -- '--output-certs' "${FAKE_CONFIG_LOG}" >/dev/null
CHECKER="${REPO_ROOT}/scripts/lib/kubernetes-reachability.sh"
expect_pass "shared checker confirms authenticated HTTPS reachability" \
  bash "${CHECKER}" --name js-csoc-dev \
    --kubeconfig "${MAGNUM_KUBECONFIG_DIR}/js-csoc-dev.yaml" \
    --minimum-ready 2 --expected-endpoint https://10.0.0.1:6443
FAKE_KUBE_SERVER=http://10.0.0.1:6443 \
  expect_fail "shared checker rejects a non-HTTPS API endpoint" \
  bash "${CHECKER}" --name js-csoc-dev \
    --kubeconfig "${MAGNUM_KUBECONFIG_DIR}/js-csoc-dev.yaml" --minimum-ready 2
FAKE_KUBE_READY_COUNT=1 \
  expect_fail "shared checker rejects insufficient Ready nodes" \
  bash "${CHECKER}" --name js-csoc-dev \
    --kubeconfig "${MAGNUM_KUBECONFIG_DIR}/js-csoc-dev.yaml" --minimum-ready 2
FAKE_KUBE_CAN_LIST_NODES=no \
  expect_fail "shared checker rejects credentials that cannot list nodes" \
  bash "${CHECKER}" --name js-csoc-dev \
    --kubeconfig "${MAGNUM_KUBECONFIG_DIR}/js-csoc-dev.yaml" --minimum-ready 2
FAKE_CLUSTER_EXISTS=true expect_pass "readiness verifies nodes, DNS, roots, and bounds" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/verify.sh"
FAKE_CLUSTER_EXISTS=true MAGNUM_VERIFY_NODE_MODE=bounds \
  expect_pass "ongoing readiness accepts worker counts within autoscaling bounds" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/verify.sh"
FAKE_CLUSTER_EXISTS=true FAKE_KUBE_UNINITIALIZED=true \
  expect_fail "readiness rejects cloud-provider-uninitialized taints" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/verify.sh"

unlink "${FAKE_NODEGROUP_UPDATE_LOG}" 2>/dev/null || true
FAKE_CLUSTER_EXISTS=true FAKE_NODEGROUP_MAX=null MAGNUM_NODEGROUP_UPDATE_TIMEOUT=5 \
  MAGNUM_WAIT_INTERVAL=0 expect_pass "default worker API bounds are reconciled idempotently" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/configure-nodegroup.sh"
grep -F -- '/max_node_count=1' "${FAKE_NODEGROUP_UPDATE_LOG}" >/dev/null

rm -f "${FAKE_AUTOSCALE_STATE}"
FAKE_CLUSTER_EXISTS=true MAGNUM_AUTO_SCALING_ENABLED=true MAGNUM_MAX_NODE_COUNT=2 \
  MAGNUM_WAIT_INTERVAL=0 \
  MAGNUM_AUTOSCALE_UP_TIMEOUT=5 MAGNUM_AUTOSCALE_DOWN_TIMEOUT=5 \
  expect_pass "autoscaling acceptance does not require an in-cluster provider deployment" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/verify-autoscaling.sh"
FAKE_CLUSTER_EXISTS=true MAGNUM_AUTO_SCALING_ENABLED=true MAGNUM_MAX_NODE_COUNT=2 \
  FAKE_AUTO_SCALING_ENABLED=false \
  expect_fail "autoscaling acceptance rejects a disabled Magnum cluster label" \
  bash "${REPO_ROOT}/scripts/bootstrap/magnum/verify-autoscaling.sh"

export MAGNUM_DIAGNOSTIC_DIR="${TEST_ROOT}/diagnostics"
FAKE_CLUSTER_EXISTS=true expect_fail "delete rejects a UUID outside ownership state" \
  bash "${REPO_ROOT}/scripts/operations/magnum/delete-owned.sh" wrong-cluster-id
[[ ! -e "${FAKE_DELETE_LOG}" ]] \
  || { printf 'not ok - mismatched UUID submitted a delete\n'; ((fail += 1)); }
FAKE_CLUSTER_EXISTS=true FAKE_CLUSTER_STATUS=DELETE_IN_PROGRESS \
  MAGNUM_DELETE_TIMEOUT=0 expect_fail "delete resumes monitoring without resubmitting" \
  bash "${REPO_ROOT}/scripts/operations/magnum/delete-owned.sh" \
    11111111-2222-3333-4444-555555555555
if [[ -e "${FAKE_DELETE_LOG}" ]]; then
  printf 'not ok - DELETE_IN_PROGRESS was resubmitted\n'
  ((fail += 1))
else
  printf 'ok - DELETE_IN_PROGRESS was not resubmitted\n'
  ((pass += 1))
fi
jq '.cluster_name = "csoc-dev"' "${MAGNUM_STATE_FILE}" >"${MAGNUM_STATE_FILE}.tmp"
mv "${MAGNUM_STATE_FILE}.tmp" "${MAGNUM_STATE_FILE}"
rm -f "${FAKE_DELETE_LOG}"
FAKE_CLUSTER_NAME=csoc-dev FAKE_CLUSTER_EXISTS=true \
  FAKE_CLUSTER_STATUS=DELETE_IN_PROGRESS MAGNUM_DELETE_TIMEOUT=0 \
  expect_fail "delete monitors permitted legacy ownership without resubmitting" \
  bash "${REPO_ROOT}/scripts/operations/magnum/delete-owned.sh" \
    11111111-2222-3333-4444-555555555555
[[ ! -e "${FAKE_DELETE_LOG}" ]] \
  || { printf 'not ok - permitted legacy deletion was resubmitted\n'; ((fail += 1)); }

printf '%s passed; %s failed\n' "${pass}" "${fail}"
(( fail == 0 ))
