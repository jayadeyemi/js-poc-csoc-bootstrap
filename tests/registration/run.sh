#!/usr/bin/env bash
# Verify all-spoke reachability isolation and registration behavior.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
mkdir -p "${TEST_ROOT}/bin"
ln -s "${SCRIPT_DIR}/fake-kubectl.sh" "${TEST_ROOT}/bin/kubectl"

export PATH="${TEST_ROOT}/bin:${PATH}"
export REACHABILITY_CHECKER="${REPO_ROOT}/cluster-registration/confirm-reachability.sh"
export FAKE_KUBECTL_LOG="${TEST_ROOT}/kubectl.log"

if sh "${REPO_ROOT}/cluster-registration/register.sh" \
  >"${TEST_ROOT}/stdout" 2>"${TEST_ROOT}/stderr"; then
  echo 'not ok - an unreachable spoke must fail the registration Job'
  exit 1
fi
grep -F 'create secret generic cluster-spoke-good' "${FAKE_KUBECTL_LOG}" >/dev/null
! grep -F 'create secret generic cluster-spoke-bad' "${FAKE_KUBECTL_LOG}" >/dev/null
grep -F 'annotate secret cluster-spoke-bad' "${FAKE_KUBECTL_LOG}" \
  | grep -F 'csoc.js2.org/reachable=false' >/dev/null
echo 'ok - one unreachable spoke does not block a reachable spoke'

: >"${FAKE_KUBECTL_LOG}"
FAKE_ALL_REACHABLE=true sh "${REPO_ROOT}/cluster-registration/register.sh" \
  >"${TEST_ROOT}/stdout" 2>"${TEST_ROOT}/stderr"
grep -F 'create secret generic cluster-spoke-good' "${FAKE_KUBECTL_LOG}" >/dev/null
grep -F 'create secret generic cluster-spoke-bad' "${FAKE_KUBECTL_LOG}" >/dev/null
[[ $(grep -c 'csoc.js2.org/reachable=true' "${FAKE_KUBECTL_LOG}") == 2 ]]
echo 'ok - every reachable spoke is confirmed and registered'
