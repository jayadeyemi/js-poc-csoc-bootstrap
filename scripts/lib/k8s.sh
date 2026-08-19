#!/usr/bin/env bash
# Kubernetes helper functions — source this file, do not execute directly.
set -euo pipefail

# Apply manifests using server-side apply (idempotent by default).
k8s::apply() {
  kubectl apply --server-side -f "$@"
}

# Apply a template file after substituting environment variables.
k8s::apply_template() {
  local template=$1
  envsubst < "${template}" | kubectl apply --server-side -f -
}

# Returns 0 if the namespace exists.
k8s::namespace_exists() {
  kubectl get namespace "$1" >/dev/null 2>&1
}

# Create namespace only if it does not already exist.
k8s::ensure_namespace() {
  local ns=$1
  if ! k8s::namespace_exists "${ns}"; then
    kubectl create namespace "${ns}"
    log::success "Namespace '${ns}' created"
  else
    log::info "Namespace '${ns}' already exists"
  fi
}

# Create (or update) a generic secret from a file, idempotently.
k8s::ensure_secret_from_file() {
  local name=$1 namespace=$2 key=$3 file=$4
  kubectl create secret generic "${name}" \
    --from-file="${key}=${file}" \
    --namespace "${namespace}" \
    --dry-run=client -o yaml \
    | kubectl apply --server-side -f -
}

# Wait until all nodes are Ready or timeout expires.
k8s::wait_nodes_ready() {
  local timeout=${1:-300}
  kubectl wait --for=condition=Ready nodes --all --timeout="${timeout}s"
}

# Block until a CAPI Cluster reaches provisioned phase.
k8s::wait_capi_cluster() {
  local cluster_name=$1 namespace=${2:-default} timeout=${3:-900}
  kubectl wait cluster "${cluster_name}" \
    --for=condition=Ready \
    --namespace "${namespace}" \
    --timeout="${timeout}s"
}

# Merge a kubeconfig file into ${KUBECONFIG:-~/.kube/config}.
k8s::merge_kubeconfig() {
  local new_cfg=$1
  local base_cfg="${KUBECONFIG:-${HOME}/.kube/config}"
  local base_dir merged_cfg backup_cfg
  base_dir=$(dirname "${base_cfg}")
  mkdir -p "${base_dir}"
  chmod 700 "${base_dir}"
  merged_cfg=$(mktemp "${base_dir}/.kubeconfig-merge.XXXXXX")
  trap 'rm -f -- "${merged_cfg}"' RETURN

  if [[ -f "${base_cfg}" ]]; then
    backup_cfg="${base_cfg}.bak.$(date -u +'%Y%m%dT%H%M%SZ')"
    cp -p "${base_cfg}" "${backup_cfg}"
    chmod 600 "${backup_cfg}"
    KUBECONFIG="${base_cfg}:${new_cfg}" kubectl config view --flatten --raw >"${merged_cfg}"
  else
    kubectl --kubeconfig="${new_cfg}" config view --flatten --raw >"${merged_cfg}"
  fi
  kubectl --kubeconfig="${merged_cfg}" config get-contexts >/dev/null
  chmod 600 "${merged_cfg}"
  mv "${merged_cfg}" "${base_cfg}"
  trap - RETURN
  log::success "Kubeconfig merged into ${base_cfg}"
}
