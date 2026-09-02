#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "${TEST_ROOT}"' EXIT HUP INT TERM
mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/work"
ln -s "${SCRIPT_DIR}/fake-kubectl.sh" "${TEST_ROOT}/bin/kubectl"
ln -s "${SCRIPT_DIR}/fake-openssl.sh" "${TEST_ROOT}/bin/openssl"
yq -r 'select(.kind == "ConfigMap" and .metadata.name == "spoke-registration-controller") | .data."reconcile.sh"' \
  "${REPO_ROOT}/controllers/registration.yaml" >"${TEST_ROOT}/reconcile.sh"
chmod +x "${TEST_ROOT}/reconcile.sh" "${SCRIPT_DIR}/fake-kubectl.sh" "${SCRIPT_DIR}/fake-openssl.sh"

export PATH="${TEST_ROOT}/bin:${PATH}"
export MANAGEMENT_SERVER=https://management.example:6443
export MANAGEMENT_CA_DATA
MANAGEMENT_CA_DATA=$(printf 'management-ca' | base64 -w0)
export MANAGEMENT_CA_SHA256
MANAGEMENT_CA_SHA256=$(printf 'management-ca' | sha256sum | cut -d' ' -f1)
export CSOC_REGISTRATION_RUN_ONCE=true
export CSOC_REGISTRATION_WORK_ROOT="${TEST_ROOT}/work"
export FAKE_KUBECTL_LOG="${TEST_ROOT}/kubectl.log"

run_scenario() {
  export FAKE_SCENARIO=$1
  export FAKE_CERT_EXPIRED=${2:-false}
  : >"${FAKE_KUBECTL_LOG}"
  "${TEST_ROOT}/reconcile.sh"
}

run_scenario creation
for expected in \
  'create secret generic cluster-shared ' \
  'create secret generic cluster-shared-platform ' \
  'create secret generic cluster-shared-monitoring ' \
  'name: csoc-central-argocd-registration-application' \
  'name: csoc-central-argocd-registration-platform' \
  'name: csoc-central-argocd-registration-monitoring' \
  'registration.csoc.js2.org/workload-credential-revision=' \
  'registration.csoc.js2.org/message=Registered'; do
  grep -F "${expected}" "${FAKE_KUBECTL_LOG}" >/dev/null || { echo "creation missed ${expected}" >&2; exit 1; }
done

run_scenario rotation true
[[ $(grep -c 'kind: CertificateSigningRequest' "${FAKE_KUBECTL_LOG}") -eq 4 ]] || {
  echo "forced rotation did not issue three Argo and one autoscaler certificate" >&2
  exit 1
}

run_scenario duplicate
grep -F 'registration.csoc.js2.org/message=DuplicateRegistration' "${FAKE_KUBECTL_LOG}" >/dev/null
if grep -F 'create secret generic cluster-shared ' "${FAKE_KUBECTL_LOG}" >/dev/null; then
  echo "duplicate registration received credentials" >&2
  exit 1
fi

run_scenario cleanup-unreachable
grep -F 'registration.csoc.js2.org/message=DeregistrationSpokeUnreachable' "${FAKE_KUBECTL_LOG}" >/dev/null
if grep -F 'remove\",\"path\":\"/metadata/finalizers/' "${FAKE_KUBECTL_LOG}" >/dev/null; then
  echo "unreachable cleanup removed the finalizer" >&2
  exit 1
fi

run_scenario cleanup
grep -F 'delete secret cluster-shared cluster-shared-platform cluster-shared-monitoring -n argocd' "${FAKE_KUBECTL_LOG}" >/dev/null
grep -F 'delete rolebindings --all-namespaces -l csoc.js2.org/registration=registration' "${FAKE_KUBECTL_LOG}" >/dev/null
grep -F '/metadata/finalizers/0' "${FAKE_KUBECTL_LOG}" >/dev/null

echo "registration creation, rotation, duplicate, unreachable, and cleanup tests passed"
