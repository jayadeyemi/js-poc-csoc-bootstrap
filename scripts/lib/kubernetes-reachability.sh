#!/bin/sh
# Read-only Kubernetes API and node readiness check shared by Magnum verification.
set -eu

fail() {
  printf 'cluster=%s reachable=false reason=%s\n' "$cluster_name" "$1" >&2
  exit 1
}

cluster_name=unknown
kubeconfig_file=
minimum_ready=
expected_endpoint=
request_timeout=15s
while [ "$#" -gt 0 ]; do
  case "$1" in
    --name) cluster_name=$2; shift 2 ;;
    --kubeconfig) kubeconfig_file=$2; shift 2 ;;
    --minimum-ready) minimum_ready=$2; shift 2 ;;
    --expected-endpoint) expected_endpoint=$2; shift 2 ;;
    --timeout) request_timeout=$2; shift 2 ;;
    *) fail invalid-arguments ;;
  esac
done

[ -r "$kubeconfig_file" ] || fail kubeconfig-unreadable
case "$minimum_ready" in ''|*[!0-9]*) fail invalid-minimum-ready ;; esac
server=$(kubectl --kubeconfig="$kubeconfig_file" config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}') || fail invalid-kubeconfig
case "$server" in https://*) ;; *) fail api-endpoint-is-not-https ;; esac
actual=$(printf '%s' "$server" | sed -e 's#^https://##' -e 's#/$##')
expected=$(printf '%s' "$expected_endpoint" | sed -e 's#^https://##' -e 's#/$##')
[ -z "$expected" ] || [ "$actual" = "$expected" ] || fail api-endpoint-mismatch
readyz=$(kubectl --kubeconfig="$kubeconfig_file" --request-timeout="$request_timeout" get --raw=/readyz 2>/dev/null) || fail readyz-unreachable
[ "$readyz" = ok ] || fail readyz-not-ok
[ "$(kubectl --kubeconfig="$kubeconfig_file" --request-timeout="$request_timeout" auth can-i list nodes 2>/dev/null)" = yes ] || fail cannot-list-nodes
report=$(kubectl --kubeconfig="$kubeconfig_file" --request-timeout="$request_timeout" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\t"}{range .spec.taints[*]}{.key}{","}{end}{"\n"}{end}') || fail node-list-unreachable
printf '%s\n' "$report" | grep -F 'node.cloudprovider.kubernetes.io/uninitialized' >/dev/null && fail cloud-provider-uninitialized
node_count=$(printf '%s\n' "$report" | awk 'NF { count++ } END { print count + 0 }')
ready_count=$(printf '%s\n' "$report" | awk -F '\t' '$2 == "True" { count++ } END { print count + 0 }')
[ "$node_count" -gt 0 ] || fail no-nodes-reported
[ "$ready_count" -eq "$node_count" ] || fail not-all-nodes-ready
[ "$ready_count" -ge "$minimum_ready" ] || fail below-minimum-ready
printf 'cluster=%s reachable=true readyNodes=%s totalNodes=%s\n' "$cluster_name" "$ready_count" "$node_count"
