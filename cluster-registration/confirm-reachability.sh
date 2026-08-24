#!/bin/sh
# Confirm authenticated Kubernetes API reachability without exposing credentials.
set -eu

usage() {
  echo "Usage: $0 --name NAME --kubeconfig FILE (--minimum-ready N | --expected-ready N) [--expected-endpoint HOST:PORT] [--timeout DURATION]" >&2
  exit 64
}

fail() {
  echo "cluster=${cluster_name:-unknown} reachable=false reason=$1" >&2
  exit 1
}

cluster_name=''
kubeconfig_file=''
minimum_ready=''
expected_ready=''
expected_endpoint=''
request_timeout='15s'

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name) cluster_name=${2:-}; shift 2 ;;
    --kubeconfig) kubeconfig_file=${2:-}; shift 2 ;;
    --minimum-ready) minimum_ready=${2:-}; shift 2 ;;
    --expected-ready) expected_ready=${2:-}; shift 2 ;;
    --expected-endpoint) expected_endpoint=${2:-}; shift 2 ;;
    --timeout) request_timeout=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$cluster_name" ] && [ -n "$kubeconfig_file" ] || usage
[ -n "$minimum_ready" ] || [ -n "$expected_ready" ] || usage
[ -z "$minimum_ready" ] || [ -z "$expected_ready" ] || usage
[ -r "$kubeconfig_file" ] || fail "kubeconfig-unreadable"

required_ready=${expected_ready:-$minimum_ready}
case "$required_ready" in
  ''|*[!0-9]*) fail "invalid-ready-node-requirement" ;;
esac
[ "$required_ready" -gt 0 ] || fail "invalid-ready-node-requirement"

if ! server=$(kubectl --kubeconfig="$kubeconfig_file" config view \
  --minify --raw -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null); then
  fail "invalid-kubeconfig"
fi
case "$server" in
  https://*) ;;
  *) fail "api-endpoint-is-not-https" ;;
esac

if [ -n "$expected_endpoint" ]; then
  actual=${server#https://}
  actual=${actual%/}
  expected=${expected_endpoint#https://}
  expected=${expected%/}
  [ "$actual" = "$expected" ] || fail "api-endpoint-mismatch"
fi

if ! readyz=$(kubectl --kubeconfig="$kubeconfig_file" \
  --request-timeout="$request_timeout" get --raw=/readyz 2>/dev/null); then
  fail "readyz-unreachable"
fi
[ "$readyz" = ok ] || fail "readyz-not-ok"

can_list=$(kubectl --kubeconfig="$kubeconfig_file" \
  --request-timeout="$request_timeout" auth can-i list nodes 2>/dev/null || true)
[ "$can_list" = yes ] || fail "cannot-list-nodes"

if ! node_report=$(kubectl --kubeconfig="$kubeconfig_file" \
  --request-timeout="$request_timeout" get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\t"}{range .spec.taints[*]}{.key}{","}{end}{"\n"}{end}' \
  2>/dev/null); then
  fail "node-list-unreachable"
fi

node_count=$(printf '%s\n' "$node_report" | awk 'NF { count++ } END { print count + 0 }')
ready_count=$(printf '%s\n' "$node_report" | awk -F '\t' '$2 == "True" { count++ } END { print count + 0 }')
if printf '%s\n' "$node_report" | grep -F 'node.cloudprovider.kubernetes.io/uninitialized' >/dev/null; then
  fail "cloud-provider-uninitialized"
fi
[ "$node_count" -gt 0 ] || fail "no-nodes-reported"
[ "$ready_count" -eq "$node_count" ] \
  || fail "ready-node-count-${ready_count}-of-${node_count}"

if [ -n "$expected_ready" ]; then
  [ "$node_count" -eq "$expected_ready" ] \
    && [ "$ready_count" -eq "$expected_ready" ] \
    || fail "ready-node-count-${ready_count}-of-${node_count}-expected-${expected_ready}"
else
  [ "$ready_count" -ge "$minimum_ready" ] \
    || fail "ready-node-count-${ready_count}-of-${node_count}-minimum-${minimum_ready}"
fi

printf 'cluster=%s reachable=true readyNodes=%s totalNodes=%s\n' \
  "$cluster_name" "$ready_count" "$node_count"
