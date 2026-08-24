#!/usr/bin/env bash
# Deterministic kubectl fake for kubeconfig and readiness tests.
set -euo pipefail
args="$*"
case "${args}" in
  *"config view --minify --raw -o jsonpath={.clusters[0].cluster.server}"*)
    printf '%s\n' "${FAKE_KUBE_SERVER:-https://10.0.0.1:6443}"
    ;;
  *"config view"*) printf 'apiVersion: v1\nkind: Config\nclusters: []\ncontexts: []\nusers: []\n' ;;
  *"config get-contexts"*) printf 'CURRENT NAME CLUSTER AUTHINFO NAMESPACE\n' ;;
  *"get --raw=/readyz"*)
    [[ "${FAKE_KUBE_READYZ:-ok}" == error ]] && exit 1
    printf '%s\n' "${FAKE_KUBE_READYZ:-ok}"
    ;;
  *"auth can-i list nodes"*)
    printf '%s\n' "${FAKE_KUBE_CAN_LIST_NODES:-yes}"
    [[ "${FAKE_KUBE_CAN_LIST_NODES:-yes}" == yes ]]
    ;;
  *"get nodes -o jsonpath="*)
    if [[ "${FAKE_KUBE_UNINITIALIZED:-false}" == true ]]; then
      printf 'control\tTrue\tnode-role.kubernetes.io/control-plane,\nworker\tTrue\tnode.cloudprovider.kubernetes.io/uninitialized,\n'
    elif [[ "${FAKE_KUBE_READY_COUNT:-2}" == 1 ]]; then
      printf 'control\tTrue\tnode-role.kubernetes.io/control-plane,\nworker\tFalse\t\n'
    else
      printf 'control\tTrue\tnode-role.kubernetes.io/control-plane,\nworker\tTrue\t\n'
    fi
    ;;
  "get nodes -o json")
    if [[ "${FAKE_KUBE_UNINITIALIZED:-false}" == true ]]; then
      printf '%s\n' '{"items":[{"metadata":{"name":"control"},"spec":{"taints":[{"key":"node-role.kubernetes.io/control-plane","effect":"NoSchedule"}]},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"worker"},"spec":{"taints":[{"key":"node.cloudprovider.kubernetes.io/uninitialized","effect":"NoSchedule"}]},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    elif [[ -n "${FAKE_AUTOSCALE_STATE:-}" && -f "${FAKE_AUTOSCALE_STATE}" \
       && $(<"${FAKE_AUTOSCALE_STATE}") == up ]]; then
      printf '%s\n' '{"items":[{"metadata":{"name":"control"},"spec":{"taints":[{"key":"node-role.kubernetes.io/control-plane","effect":"NoSchedule"}]},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"worker-1"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"worker-2"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    else
      printf '%s\n' '{"items":[{"metadata":{"name":"control"},"spec":{"taints":[{"key":"node-role.kubernetes.io/control-plane","effect":"NoSchedule"}]},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"worker"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    fi
    ;;
  "apply -f -")
    cat >/dev/null
    printf 'up\n' >"${FAKE_AUTOSCALE_STATE:?FAKE_AUTOSCALE_STATE is required}"
    ;;
  *"scale deployment/scale-pressure --replicas=0")
    printf 'down\n' >"${FAKE_AUTOSCALE_STATE:?FAKE_AUTOSCALE_STATE is required}"
    ;;
  *"get events -A --field-selector reason=TriggeredScaleUp --sort-by=.lastTimestamp")
    printf 'No resources found\n'
    ;;
  *"rollout status"*|create\ namespace*|*" run dns-smoke "*|*" wait --for=jsonpath="*|delete\ namespace*) ;;
  *" logs dns-smoke") printf 'Name: kubernetes.default.svc.cluster.local\n' ;;
  *) printf 'Unhandled fake kubectl command: %s\n' "${args}" >&2; exit 64 ;;
esac
