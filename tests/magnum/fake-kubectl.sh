#!/usr/bin/env bash
# Deterministic kubectl fake for kubeconfig and readiness tests.
set -euo pipefail
args="$*"
case "${args}" in
  *"config view"*) printf 'apiVersion: v1\nkind: Config\nclusters: []\ncontexts: []\nusers: []\n' ;;
  *"config get-contexts"*) printf 'CURRENT NAME CLUSTER AUTHINFO NAMESPACE\n' ;;
  "get --raw=/readyz") printf 'ok\n' ;;
  "get nodes -o json")
    if [[ "${FAKE_KUBE_UNINITIALIZED:-false}" == true ]]; then
      printf '%s\n' '{"items":[{"metadata":{"name":"control"},"spec":{"taints":[{"key":"node-role.kubernetes.io/control-plane","effect":"NoSchedule"}]},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"worker"},"spec":{"taints":[{"key":"node.cloudprovider.kubernetes.io/uninitialized","effect":"NoSchedule"}]},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    else
      printf '%s\n' '{"items":[{"metadata":{"name":"control"},"spec":{"taints":[{"key":"node-role.kubernetes.io/control-plane","effect":"NoSchedule"}]},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"worker"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    fi
    ;;
  *"rollout status"*|create\ namespace*|*" run dns-smoke "*|*" wait --for=jsonpath="*|delete\ namespace*) ;;
  *" logs dns-smoke") printf 'Name: kubernetes.default.svc.cluster.local\n' ;;
  *) printf 'Unhandled fake kubectl command: %s\n' "${args}" >&2; exit 64 ;;
esac
