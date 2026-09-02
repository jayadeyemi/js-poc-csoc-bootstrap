#!/usr/bin/env bash
# Render every initially supported chart and compare its GVKs with AppProject policy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
CATALOG_ROOT="${WORKSPACE_ROOT}/js-poc-csoc-app-catalog"
CONFIG_ROOT="${WORKSPACE_ROOT}/../references/config"
source "${REPO_ROOT}/versions.env"

for command_name in helm jq kubectl yq; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "missing ${command_name}" >&2; exit 1; }
done

render_dir=$(mktemp -d)
trap 'rm -rf -- "${render_dir}"' EXIT HUP INT TERM
boundary_rgd="${CATALOG_ROOT}/rgds/v2-hubs/bindings/applicationboundary.rgds.yaml"
foundation_rgd="${CATALOG_ROOT}/rgds/v2-hubs/infrastructure/clusterfoundation.yaml"

assert_allowed() {
  rendered=$1 policy_rgd=$2 policy_id=$3
  while IFS="$(printf '\t')" read -r api_version kind; do
    [[ -n "${kind}" ]] || continue
    case "${api_version}" in */*) group=${api_version%/*} ;; *) group= ;; esac
    case "${kind}" in
      Namespace|CustomResourceDefinition|ClusterRole|ClusterRoleBinding|StorageClass|CSIDriver|MutatingWebhookConfiguration|ValidatingWebhookConfiguration|Installation|APIServer|Goldmane|Whisker)
        list=clusterResourceWhitelist ;;
      *) list=namespaceResourceWhitelist ;;
    esac
    yq -e ".spec.resources[] | select(.id == \"${policy_id}\") | .template.spec.${list}[] | select(.group == \"${group}\" and .kind == \"${kind}\")" \
      "${policy_rgd}" >/dev/null || {
        echo "${policy_id} AppProject does not allow rendered ${api_version} ${kind}" >&2
        exit 1
      }
  done < <(yq eval-all -o=json '[select(.kind != null) | {"apiVersion": .apiVersion, "kind": .kind}]' "${rendered}" \
    | jq -r '.[] | [.apiVersion, .kind] | @tsv' | sort -u)
}

helm template jupyterhub jupyterhub \
  --repo https://hub.jupyter.org/helm-chart \
  --version "${JUPYTERHUB_CHART_VERSION}" --namespace jupyterhub \
  --values "${CONFIG_ROOT}/projects/csoc-v2/jupyterhub/values.yaml" \
  --set-string hub.config.JupyterHub.authenticator_class=dummy \
  --set hub.config.Authenticator.allow_all=true \
  --set-string proxy.service.type=ClusterIP --set proxy.https.enabled=false \
  >"${render_dir}/jupyterhub.yaml"
assert_allowed "${render_dir}/jupyterhub.yaml" "${boundary_rgd}" hubproject
if yq eval-all -o=json '[select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding" or .kind == "PriorityClass" or .kind == "DaemonSet")]' \
    "${render_dir}/jupyterhub.yaml" | jq -e 'length > 0' >/dev/null; then
  echo "JupyterHub escaped its namespace-scoped delivery contract" >&2
  exit 1
fi

helm template monitoring kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts \
  --version "${KUBE_PROMETHEUS_STACK_CHART_VERSION}" --namespace monitoring \
  --include-crds --values "${CONFIG_ROOT}/projects/csoc-v2/monitoring/values.yaml" \
  --set grafana.enabled=false --set alertmanager.enabled=false \
  --set-string prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=cinder-retain \
  --set-string prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=20Gi \
  >"${render_dir}/monitoring.yaml"
yq eval-all -o=json '[select(.kind == "CustomResourceDefinition")]' "${render_dir}/monitoring.yaml" | jq -e 'length > 0' >/dev/null \
  || { echo "monitoring render omitted CRDs" >&2; exit 1; }
assert_allowed "${render_dir}/monitoring.yaml" "${boundary_rgd}" monitoringproject

for application_id in ccm cinder autoscaler; do
  yq -o=yaml ".spec.resources[] | select(.id == \"${application_id}\") | .template.spec.source.helm.valuesObject" \
    "${foundation_rgd}" >"${render_dir}/${application_id}-values.yaml"
done
helm template calico tigera-operator \
  --repo https://docs.tigera.io/calico/charts --version "v${CALICO_VERSION#v}" \
  --namespace tigera-operator >"${render_dir}/calico.yaml"
helm template openstack-ccm openstack-cloud-controller-manager \
  --repo https://kubernetes.github.io/cloud-provider-openstack --version "${OPENSTACK_CCM_CHART_VERSION}" \
  --namespace kube-system --values "${render_dir}/ccm-values.yaml" >"${render_dir}/ccm.yaml"
helm template openstack-cinder-csi openstack-cinder-csi \
  --repo https://kubernetes.github.io/cloud-provider-openstack --version "${OPENSTACK_CINDER_CSI_CHART_VERSION}" \
  --namespace kube-system --values "${render_dir}/cinder-values.yaml" >"${render_dir}/cinder.yaml"
helm template cluster-autoscaler cluster-autoscaler \
  --repo https://kubernetes.github.io/autoscaler --version "${CLUSTER_AUTOSCALER_CHART_VERSION}" \
  --namespace kube-system --values "${render_dir}/autoscaler-values.yaml" >"${render_dir}/autoscaler.yaml"
kubectl kustomize "${CONFIG_ROOT}/projects/csoc-v2/foundation" >"${render_dir}/foundation.yaml"

for rendered in calico ccm cinder autoscaler foundation; do
  assert_allowed "${render_dir}/${rendered}.yaml" "${foundation_rgd}" platformproject
done
yq eval-all -o=json '[select(.kind == "Deployment" and .metadata.name == "openstack-cinder-csi-controllerplugin")]' \
  "${render_dir}/cinder.yaml" | jq -e '
    length == 1 and
    .[0].spec.template.spec.nodeSelector["csoc.js2.org/pool-class"] == "system" and
    any(.[0].spec.template.spec.tolerations[]; .key == "csoc.js2.org/pool-class" and .value == "system" and .effect == "NoSchedule")
  ' >/dev/null || {
    echo "Cinder CSI controller is not pinned and tolerated onto the system pool" >&2
    exit 1
  }

echo "supported v2 chart, schema, GVK, AppProject, and scheduling renders passed"
