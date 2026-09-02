#!/usr/bin/env bash
# Compile the compatibility RGD package in its declared Argo dependency order.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CATALOG_ROOT="${APP_CATALOG_ROOT:-${REPO_ROOT}/../js-poc-csoc-app-catalog}"
PACKAGE_ROOT="${CATALOG_ROOT}/rgds/v1-samples"

[[ "${CSOC_V1_ACTIVATION_APPROVED:-false}" == true ]] || {
  echo "set CSOC_V1_ACTIVATION_APPROVED=true for an explicitly selected non-production CSOC" >&2
  exit 1
}
[[ -n "${KUBECONFIG:-}" && -f "${KUBECONFIG}" ]] || { echo "KUBECONFIG is required" >&2; exit 1; }
expected_context=${CSOC_EXPECTED_CONTEXT:?CSOC_EXPECTED_CONTEXT is required}
actual_context=$(kubectl config current-context)
[[ "${actual_context}" == "${expected_context}" ]] || {
  echo "refusing v1 activation on context ${actual_context}; expected ${expected_context}" >&2
  exit 1
}

mapfile -t ordered_manifests < <(
  find "${PACKAGE_ROOT}" -type f -name '*.rgd.yaml' -print0 |
    while IFS= read -r -d '' manifest; do
      printf '%s|%s\n' \
        "$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave"' "${manifest}")" \
        "${manifest}"
    done | sort -t '|' -k1,1n -k2,2 | cut -d '|' -f2-
)
[[ ${#ordered_manifests[@]} -eq 20 ]] || {
  echo "expected 20 v1 RGDs, found ${#ordered_manifests[@]}" >&2
  exit 1
}

deadline=$((SECONDS + ${CSOC_V1_COMPILE_TIMEOUT_SECONDS:-1200}))
wait_active() {
  local rgd=$1 state revision_ready
  while true; do
    state=$(kubectl get resourcegraphdefinition "${rgd}" -o jsonpath='{.status.state}' 2>/dev/null || true)
    revision_ready=$(kubectl get graphrevisions.internal.kro.run -o json 2>/dev/null |
      jq -r --arg rgd "${rgd}" \
        '[.items[] | select(.spec.snapshot.name == $rgd) | .status.conditions[]? | select(.type == "Ready" and .status == "True")] | length' || true)
    [[ "${state}" == Active && "${revision_ready:-0}" -ge 1 ]] && return 0
    if (( SECONDS >= deadline )); then
      kubectl get resourcegraphdefinition "${rgd}" -o yaml >&2 || true
      echo "timed out waiting for Active GraphRevision: ${rgd}" >&2
      exit 1
    fi
    sleep 5
  done
}

recreate_inactive_if_approved() {
  local manifest=$1 rgd=$2 state group kind instances
  state=$(kubectl get resourcegraphdefinition "${rgd}" -o jsonpath='{.status.state}' 2>/dev/null || true)
  [[ "${state}" == Inactive ]] || return 0
  [[ "${CSOC_V1_RECREATE_INACTIVE_APPROVED:-false}" == true ]] || {
    echo "${rgd} is Inactive; recovery requires CSOC_V1_RECREATE_INACTIVE_APPROVED=true" >&2
    exit 1
  }
  group=$(yq -r '.spec.schema.group' "${manifest}")
  kind=$(yq -r '.spec.schema.kind' "${manifest}")
  instances=$(kubectl get "${kind}.${group}" --all-namespaces -o name 2>/dev/null || true)
  [[ -z "${instances}" ]] || {
    echo "refusing to recreate ${rgd}; ${kind}.${group} instances exist" >&2
    exit 1
  }
  echo "recreating inactive zero-instance RGD ${rgd}" >&2
  kubectl delete resourcegraphdefinition "${rgd}" --wait=true --timeout=2m >/dev/null
}

for manifest in "${ordered_manifests[@]}"; do
  rgd=$(yq -r '.metadata.name' "${manifest}")
  recreate_inactive_if_approved "${manifest}" "${rgd}"
  kubectl apply --server-side --dry-run=server --field-manager=csoc-v1-rgd-publisher \
    -f "${manifest}" >/dev/null
  kubectl apply --server-side --field-manager=csoc-v1-rgd-publisher -f "${manifest}" >/dev/null
  wait_active "${rgd}"
done

echo "all ${#ordered_manifests[@]} v1 RGDs have an Active Ready GraphRevision"
