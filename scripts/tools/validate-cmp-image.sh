#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_ROOT="$(cd "${REPO_ROOT}/../../references/config" && pwd)"
source "${REPO_ROOT}/versions.env"
image=${1:-csoc-sops-helm-cmp:0.1.0}

actual=$(
  docker run --rm --entrypoint /bin/sh "$image" -c '
    printf "%s\n" "$(id -u)" "$(helm version --short | sed "s/+.*//")" \
      "$(sops --version | head -1 | awk "{print \$2}")" "$(age --version)" \
      "$(kustomize version)" "$(yq --version | awk "{print \$NF}")"
    ls -1 /opt/csoc/charts | sort
  '
)
expected=$(printf '%s\n' 10001 "v${HELM_VERSION}" "${SOPS_VERSION}" "v${AGE_VERSION}" \
  "v${KUSTOMIZE_VERSION}" "v${YQ_VERSION}" \
  "jupyterhub-${JUPYTERHUB_CHART_VERSION}.tgz" \
  "kube-prometheus-stack-${KUBE_PROMETHEUS_STACK_CHART_VERSION}.tgz")
[[ "$actual" == "$expected" ]] || {
  diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") || true
  echo "CMP image does not match the version manifest" >&2
  exit 1
}

render_dir=$(mktemp -d)
trap 'rm -rf -- "${render_dir}"' EXIT HUP INT TERM
common=(
  --rm --entrypoint /usr/local/bin/csoc-cmp-generate
  --volume "${CONFIG_ROOT}:/workspace:ro" --workdir /workspace
  --env ARGOCD_APP_REVISION=0123456789abcdef0123456789abcdef01234567
)
docker run "${common[@]}" \
  --env ARGOCD_APP_NAME=jupyterhub --env ARGOCD_APP_DEST_NAMESPACE=jupyterhub \
  --env ARGOCD_ENV_MODE=helm --env ARGOCD_ENV_CONFIG_PATH=projects/csoc-v2/jupyterhub \
  --env ARGOCD_ENV_HELM_CHART=jupyterhub/jupyterhub --env "ARGOCD_ENV_HELM_VERSION=${JUPYTERHUB_CHART_VERSION}" \
  --env ARGOCD_ENV_JUPYTERHUB_AUTH_MODE=dummy --env ARGOCD_ENV_ENDPOINT_PLACEMENT=clusterIP \
  --env ARGOCD_ENV_ENDPOINT_ALLOWED_CIDR= --env ARGOCD_ENV_ENDPOINT_HOSTNAME= \
  --env ARGOCD_ENV_TLS_MODE=none --env ARGOCD_ENV_TLS_SECRET_NAME= \
  --env ARGOCD_ENV_HUB_DB_STORAGE_CLASS=cinder-retain --env ARGOCD_ENV_HUB_DB_SIZE_GIB=1 \
  --env ARGOCD_ENV_HOME_STORAGE_CLASS=cinder-retain --env ARGOCD_ENV_HOME_SIZE_GIB=10 \
  "${image}" >"${render_dir}/jupyterhub.yaml"
yq eval-all -o=json '[select(.kind == "PersistentVolumeClaim")]' "${render_dir}/jupyterhub.yaml" \
  | jq -e 'length == 1 and .[0].spec.resources.requests.storage == "1Gi"' >/dev/null

docker run "${common[@]}" \
  --env ARGOCD_APP_NAME=monitoring --env ARGOCD_APP_DEST_NAMESPACE=monitoring \
  --env ARGOCD_ENV_MODE=helm --env ARGOCD_ENV_CONFIG_PATH=projects/csoc-v2/monitoring \
  --env ARGOCD_ENV_HELM_CHART=prometheus-community/kube-prometheus-stack \
  --env "ARGOCD_ENV_HELM_VERSION=${KUBE_PROMETHEUS_STACK_CHART_VERSION}" \
  --env ARGOCD_ENV_MONITORING_GRAFANA_ENABLED=false --env ARGOCD_ENV_MONITORING_ALERTMANAGER_ENABLED=false \
  --env ARGOCD_ENV_PROMETHEUS_STORAGE_CLASS=cinder-retain --env ARGOCD_ENV_PROMETHEUS_STORAGE_SIZE_GIB=20 \
  "${image}" >"${render_dir}/monitoring.yaml"
yq eval-all -o=json '[select(.kind == "CustomResourceDefinition")]' "${render_dir}/monitoring.yaml" \
  | jq -e 'length > 0' >/dev/null

if docker run "${common[@]}" \
    --env ARGOCD_APP_NAME=bad --env ARGOCD_APP_DEST_NAMESPACE=default \
    --env ARGOCD_ENV_MODE=helm --env ARGOCD_ENV_CONFIG_PATH=projects/csoc-v2/jupyterhub \
    --env ARGOCD_ENV_UNUSED_INPUT=must-fail "${image}" >/dev/null 2>&1; then
  echo "CMP accepted an unknown input" >&2
  exit 1
fi
if docker run "${common[@]}" \
    --env ARGOCD_APP_NAME=bad --env ARGOCD_APP_DEST_NAMESPACE=default \
    --env ARGOCD_ENV_MODE=helm --env ARGOCD_ENV_CONFIG_PATH=projects/csoc-v2/jupyterhub \
    --env ARGOCD_ENV_HELM_CHART=jupyterhub/jupyterhub --env "ARGOCD_ENV_HELM_VERSION=${JUPYTERHUB_CHART_VERSION}" \
    "${image}" >/dev/null 2>&1; then
  echo "CMP accepted missing mode-specific inputs" >&2
  exit 1
fi

echo "CMP image and functional render contracts verified: ${image}"
