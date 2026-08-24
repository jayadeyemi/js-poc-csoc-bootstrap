#!/bin/sh
# Reconcile every reachable SpokeCluster into an Argo CD cluster Secret.
set -eu

REACHABILITY_CHECKER=${REACHABILITY_CHECKER:-/opt/csoc/bin/confirm-reachability.sh}
WORK_DIR=$(mktemp -d)
CLUSTER_LIST="$WORK_DIR/clusters"
FAILURES="$WORK_DIR/failures"
: >"$FAILURES"

cleanup() {
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

record_unreachable() {
  check_namespace=$1
  check_name=$2
  check_reason=$3
  checked_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  printf '%s/%s\n' "$check_namespace" "$check_name" >>"$FAILURES"
  echo "[registration] $check_name: unreachable ($check_reason)"
  if kubectl get secret "cluster-${check_name}" -n argocd >/dev/null 2>&1; then
    kubectl annotate secret "cluster-${check_name}" -n argocd --overwrite \
      csoc.js2.org/reachable=false \
      "csoc.js2.org/reachability-checked-at=${checked_at}" >/dev/null
  fi
}

echo "[registration] Starting cluster registration pass"
kubectl get spokecluster --all-namespaces \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' \
  >"$CLUSTER_LIST"

while IFS="$(printf '\t')" read -r namespace name; do
  [ -n "$name" ] || continue
  enabled=$(kubectl get spokecluster "$name" -n "$namespace" \
    -o jsonpath='{.spec.registration.enabled}' 2>/dev/null || true)
  ready=$(kubectl get spokecluster "$name" -n "$namespace" \
    -o jsonpath='{.status.ready}' 2>/dev/null || true)
  endpoint=$(kubectl get spokecluster "$name" -n "$namespace" \
    -o jsonpath='{.status.endpoint}' 2>/dev/null || true)

  [ "$enabled" != false ] \
    || { echo "[registration] $name: registration disabled"; continue; }
  [ "$ready" = true ] && [ -n "$endpoint" ] \
    || { echo "[registration] $name: not ready"; continue; }

  kubeconfig_file="$WORK_DIR/${namespace}-${name}.kubeconfig"
  kubeconfig_data="$WORK_DIR/${namespace}-${name}.kubeconfig.base64"
  if ! kubectl get secret "${name}-kubeconfig" -n "$namespace" \
    -o jsonpath='{.data.value}' >"$kubeconfig_data"; then
    record_unreachable "$namespace" "$name" kubeconfig-secret-unavailable
    continue
  fi
  if ! base64 -d <"$kubeconfig_data" >"$kubeconfig_file"; then
    record_unreachable "$namespace" "$name" kubeconfig-secret-invalid
    continue
  fi
  rm -f -- "$kubeconfig_data"
  chmod 600 "$kubeconfig_file"

  control_planes=$(kubectl get spokecluster "$name" -n "$namespace" \
    -o jsonpath='{.spec.controlPlane.count}' 2>/dev/null || true)
  minimum_workers=$(kubectl get spokecluster "$name" -n "$namespace" \
    -o jsonpath='{.spec.kubernetes.minNodes}' 2>/dev/null || true)
  case "$control_planes" in
    ''|*[!0-9]*) record_unreachable "$namespace" "$name" invalid-control-plane-count; continue ;;
  esac
  case "$minimum_workers" in
    ''|*[!0-9]*) record_unreachable "$namespace" "$name" invalid-minimum-worker-count; continue ;;
  esac
  minimum_ready=$((control_planes + minimum_workers))

  if ! "$REACHABILITY_CHECKER" \
    --name "$name" \
    --kubeconfig "$kubeconfig_file" \
    --minimum-ready "$minimum_ready" \
    --expected-endpoint "$endpoint" \
    --timeout 15s; then
    record_unreachable "$namespace" "$name" kubectl-reachability-check-failed
    continue
  fi

  server=$(kubectl config view --kubeconfig="$kubeconfig_file" \
    -o jsonpath='{.clusters[0].cluster.server}' --raw)
  ca=$(kubectl config view --kubeconfig="$kubeconfig_file" \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' --raw)
  cert=$(kubectl config view --kubeconfig="$kubeconfig_file" \
    -o jsonpath='{.users[0].user.client-certificate-data}' --raw)
  key=$(kubectl config view --kubeconfig="$kubeconfig_file" \
    -o jsonpath='{.users[0].user.client-key-data}' --raw)

  customer=$(kubectl get spokecluster "$name" -n "$namespace" -o \
    jsonpath="{.spec.registration.labels['csoc\.js2\.org/customer']}" 2>/dev/null || true)
  environment=$(kubectl get spokecluster "$name" -n "$namespace" -o \
    jsonpath="{.spec.registration.labels['csoc\.js2\.org/environment']}" 2>/dev/null || true)
  ownership=$(kubectl get spokecluster "$name" -n "$namespace" -o \
    jsonpath="{.spec.registration.labels['csoc\.js2\.org/ownership']}" 2>/dev/null || true)
  hello=$(kubectl get spokecluster "$name" -n "$namespace" -o \
    jsonpath="{.spec.registration.labels['csoc\.js2\.org/hello-csoc']}" 2>/dev/null || true)
  security=$(kubectl get spokecluster "$name" -n "$namespace" \
    -o jsonpath='{.spec.capabilities.security}' 2>/dev/null || true)
  observability=$(kubectl get spokecluster "$name" -n "$namespace" \
    -o jsonpath='{.spec.capabilities.observability}' 2>/dev/null || true)
  [ "$security" = true ] && security=enabled || security=disabled
  [ "$observability" = true ] && observability=enabled || observability=disabled
  [ -n "$ownership" ] || ownership=csoc

  argocd_config_file="$WORK_DIR/${namespace}-${name}.argocd-config.json"
  printf '{"tlsClientConfig":{"caData":"%s","certData":"%s","keyData":"%s"}}' \
    "$ca" "$cert" "$key" >"$argocd_config_file"
  chmod 600 "$argocd_config_file"
  kubectl create secret generic "cluster-${name}" -n argocd \
    --from-literal="name=${name}" \
    --from-literal="server=${server}" \
    --from-file="config=${argocd_config_file}" \
    --dry-run=client -o yaml \
  | kubectl apply --server-side -f - >/dev/null
  kubectl label secret "cluster-${name}" -n argocd --overwrite \
    argocd.argoproj.io/secret-type=cluster \
    csoc.js2.org/type=spoke \
    "csoc.js2.org/name=${name}" \
    "csoc.js2.org/customer=${customer}" \
    "csoc.js2.org/environment=${environment}" \
    "csoc.js2.org/ownership=${ownership}" \
    "csoc.js2.org/hello-csoc=${hello}" \
    "csoc.js2.org/security=${security}" \
    "csoc.js2.org/observability=${observability}" >/dev/null
  kubectl annotate secret "cluster-${name}" -n argocd --overwrite \
    csoc.js2.org/reachable=true \
    "csoc.js2.org/reachability-checked-at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" >/dev/null

  rm -f -- "$kubeconfig_file" "$argocd_config_file"
  echo "[registration] $name: reachable; credentials and labels reconciled"
done <"$CLUSTER_LIST"

if [ -s "$FAILURES" ]; then
  failure_count=$(wc -l <"$FAILURES" | tr -d ' ')
  echo "[registration] ${failure_count} spoke reachability check(s) failed"
  exit 1
fi
