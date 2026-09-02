#!/usr/bin/env bash
# Exercise a real KRO-generated CAPI MachineDeployment and prove replicas is autoscaler-owned.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FLEET_ROOT="${REPO_ROOT}/../js-poc-csoc-fleet"

[[ "${CSOC_V2_REPLICAS_TEST_APPROVED:-false}" == true ]] || {
  echo "set CSOC_V2_REPLICAS_TEST_APPROVED=true for the retained non-production kind cluster" >&2
  exit 1
}
[[ -n "${KUBECONFIG:-}" && -f "${KUBECONFIG}" ]] || { echo "KUBECONFIG is required" >&2; exit 1; }
expected_context=${CSOC_EXPECTED_CONTEXT:?CSOC_EXPECTED_CONTEXT is required}
[[ $(kubectl config current-context) == "${expected_context}" ]] || {
  echo "refusing replicas test outside ${expected_context}" >&2
  exit 1
}

namespace=csoc-v2-replicas-test
account=replicas-test
candidate="${FLEET_ROOT}/environments/staging/accounts/test-poc/hello-app/dev-v2"
fixture=$(mktemp)
trap 'rm -f -- "${fixture}"' EXIT HUP INT TERM

kubectl create namespace "${namespace}" --dry-run=client -o yaml \
  | yq '.metadata.labels."csoc.js2.org/account" = "replicas-test"' \
  | kubectl apply -f - >/dev/null
kubectl -n "${namespace}" create secret generic replicas-test-cloud-config \
  --from-literal=clouds.yaml='clouds: {}' --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null

kubectl kustomize "${candidate}" \
  | yq eval-all '
      select(.kind == "SpokeAccount" or .kind == "MachineProfile" or
             .kind == "SpokeNetwork" or .kind == "WorkloadCluster" or
             .kind == "SpokeNodePool") |
      .metadata.namespace = "csoc-v2-replicas-test" |
      with(select(.kind == "SpokeAccount");
        .metadata.name = "replicas-test" |
        .spec.credentialSecretName = "replicas-test-cloud-config") |
      with(select(.spec.accountRef.name == "test-poc");
        .spec.accountRef.name = "replicas-test")
    ' >"${fixture}"
kubectl apply -f "${fixture}" >/dev/null

for _ in $(seq 1 60); do
  if kubectl -n "${namespace}" get machinedeployment cpu >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kubectl -n "${namespace}" get machinedeployment cpu >/dev/null

apply_autoscaler_replicas() {
  local replicas=$1
  kubectl apply --server-side --field-manager=cluster-autoscaler -f - >/dev/null <<EOF
apiVersion: cluster.x-k8s.io/v1beta2
kind: MachineDeployment
metadata:
  name: cpu
  namespace: ${namespace}
spec:
  replicas: ${replicas}
EOF
}

assert_ownership() {
  local expected=$1 document
  document=$(kubectl -n "${namespace}" get machinedeployment cpu -o json --show-managed-fields)
  jq -e --argjson expected "${expected}" '
    (.spec.replicas == $expected) and
    any(.metadata.managedFields[];
      .manager == "cluster-autoscaler" and .fieldsV1["f:spec"]["f:replicas"] != null) and
    all(.metadata.managedFields[];
      .manager != "kro.run/applyset" or .fieldsV1["f:spec"]["f:replicas"] == null)
  ' <<<"${document}" >/dev/null
}

apply_autoscaler_replicas 1
assert_ownership 1
kubectl -n "${namespace}" annotate spokenodepool cpu \
  "csoc.js2.org/forced-reconcile=$(date -u +%s%N)" --overwrite >/dev/null
sleep 6
assert_ownership 1

# Return the retained fixture to its declared 0-node minimum without changing ownership.
apply_autoscaler_replicas 0
kubectl -n "${namespace}" annotate spokenodepool cpu \
  "csoc.js2.org/forced-reconcile=$(date -u +%s%N)" --overwrite >/dev/null
sleep 6
assert_ownership 0

echo "KRO preserved Cluster Autoscaler ownership of MachineDeployment.spec.replicas across forced reconciles"
