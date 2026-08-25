#!/usr/bin/env bash
# Static safety contract for the controller-led spoke teardown operation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DESTROY_SCRIPT="${REPO_ROOT}/scripts/operations/spokes/destroy-spoke.sh"

bash -n "${DESTROY_SCRIPT}"

for required in \
  'git -C "${FLEET_ROOT}" fetch --quiet origin main' \
  'csoc-fleet has not compared the exact fleet origin/main retirement commit' \
  'csoc-fleet must complete a non-pruning sync at the retirement commit' \
  'credentials::metadata' \
  'kubectl api-resources --api-group=csoc.js2.org --namespaced=true' \
  'independently owned graphs' \
  'secretName: ${SPOKE}-kubeconfig' \
  'kubectl wait job "${WORKLOAD_CLEANUP_JOB}"' \
  'kubectl delete spokecluster' \
  'kubectl delete "${NETWORK_KIND}"' \
  'kubectl delete spokekeypair'; do
  rg -Fq "${required}" "${DESTROY_SCRIPT}" \
    || { printf 'not ok - missing destroy safety contract: %s\n' "${required}" >&2; exit 1; }
done

workload_line=$(rg -n -F 'WORKLOAD_CLEANUP_JOB=' "${DESTROY_SCRIPT}" | head -1 | cut -d: -f1)
cluster_line=$(rg -n -F 'kubectl delete spokecluster' "${DESTROY_SCRIPT}" | head -1 | cut -d: -f1)
network_line=$(rg -n -F 'kubectl delete "${NETWORK_KIND}"' "${DESTROY_SCRIPT}" | head -1 | cut -d: -f1)
keypair_line=$(rg -n -F 'kubectl delete spokekeypair' "${DESTROY_SCRIPT}" | head -1 | cut -d: -f1)
(( workload_line < cluster_line && cluster_line < network_line && network_line < keypair_line )) \
  || { printf 'not ok - teardown order is not workload -> CAPI -> network -> keypair\n' >&2; exit 1; }

if rg -n 'openstack[[:space:]]+(server|network|subnet|router|loadbalancer)[[:space:]]+delete' \
    "${DESTROY_SCRIPT}"; then
  printf 'not ok - destroy script bypasses controllers with a raw OpenStack delete\n' >&2
  exit 1
fi
if rg -n '(--force|finalizers|patch[[:space:]].*finalizer)' "${DESTROY_SCRIPT}"; then
  printf 'not ok - destroy script contains force/finalizer bypasses\n' >&2
  exit 1
fi
if rg -n 'base64 -d|WORKLOAD_KUBECONFIG' "${DESTROY_SCRIPT}"; then
  printf 'not ok - destroy script copies the workload kubeconfig to the operator filesystem\n' >&2
  exit 1
fi

if bash "${DESTROY_SCRIPT}" >/dev/null 2>&1; then
  printf 'not ok - destroy script accepted an unconfirmed request\n' >&2
  exit 1
fi

printf 'ok - spoke teardown requires Git/Argo/credential/confirmation gates\n'
printf 'ok - spoke teardown order is workload -> CAPI/CAPO -> KRO/ORC\n'
printf 'ok - spoke teardown has no raw OpenStack delete or finalizer bypass\n'
printf 'ok - identity deletion fails closed when optional or future RGDs remain\n'
