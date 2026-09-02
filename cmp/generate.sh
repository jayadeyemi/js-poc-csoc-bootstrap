#!/bin/sh
# Offline renderer: exact commits, fixed input names, memory-backed temporary data.
set -eu

allowed='MODE CONFIG_PATH EXPECTED_SECRETS HELM_CHART HELM_VERSION JUPYTERHUB_AUTH_MODE ENDPOINT_PLACEMENT ENDPOINT_ALLOWED_CIDR ENDPOINT_HOSTNAME TLS_MODE TLS_SECRET_NAME HUB_DB_STORAGE_CLASS HUB_DB_SIZE_GIB HOME_STORAGE_CLASS HOME_SIZE_GIB MONITORING_GRAFANA_ENABLED MONITORING_ALERTMANAGER_ENABLED PROMETHEUS_STORAGE_CLASS PROMETHEUS_STORAGE_SIZE_GIB REGISTRY_STORAGE_TYPE REGISTRY_CLAIM_NAME REGISTRY_S3_BUCKET REGISTRY_S3_ENDPOINT STORAGE_MODE STORAGE_CLASS STORAGE_SIZE_GIB STORAGE_VOLUME_ID STORAGE_CLAIM_NAME STORAGE_PV_NAME'
for variable in $(env | sed -n 's/^ARGOCD_ENV_\([^=]*\)=.*/\1/p'); do
  case " $allowed " in
    *" $variable "*) ;;
    *) echo "unsupported CMP input: ${variable}" >&2; exit 1 ;;
  esac
done

revision=${ARGOCD_APP_REVISION:-}
case "$revision" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) echo "CMP requires an exact 40-character source commit" >&2; exit 1 ;;
esac

mode=${ARGOCD_ENV_MODE:-}
config_path=${ARGOCD_ENV_CONFIG_PATH:-}
case "$config_path" in ''|/*|*..*) echo "invalid CONFIG_PATH" >&2; exit 1 ;; esac
[ -e "$config_path" ] || { echo "CONFIG_PATH does not exist: $config_path" >&2; exit 1; }

reject_remote_kustomize_sources() {
  find "$config_path" -type f \( -name kustomization.yaml -o -name kustomization.yml \) -print \
    | while IFS= read -r kustomization; do
        yq -r '(.resources[]?, .components[]?, .bases[]?)' "$kustomization" \
          | while IFS= read -r source; do
              case "$source" in *://*|git::*|github.com/*) echo "runtime Kustomize download forbidden: $source" >&2; exit 1 ;; esac
            done
      done
}

case "$mode" in
  storage)
    storage_mode=${ARGOCD_ENV_STORAGE_MODE:-}
    storage_class=${ARGOCD_ENV_STORAGE_CLASS:-}
    storage_size=${ARGOCD_ENV_STORAGE_SIZE_GIB:-}
    storage_volume=${ARGOCD_ENV_STORAGE_VOLUME_ID:-}
    storage_claim=${ARGOCD_ENV_STORAGE_CLAIM_NAME:-}
    storage_pv=${ARGOCD_ENV_STORAGE_PV_NAME:-}
    case "$storage_mode" in fixed) ;; *) echo "storage renderer only provisions fixed retained volumes" >&2; exit 1 ;; esac
    case "$storage_class" in cinder-retain) ;; *) echo "invalid storage class" >&2; exit 1 ;; esac
    case "$storage_size" in ''|*[!0-9]*) echo "invalid storage size" >&2; exit 1 ;; esac
    [ "$storage_size" -ge 1 ] && [ "$storage_size" -le 16384 ] || { echo "storage size outside 1..16384 GiB" >&2; exit 1; }
    for resource_name in "$storage_claim" "$storage_pv"; do
      case "$resource_name" in ''|*[!a-z0-9-]*|-*|*-) echo "invalid storage resource name" >&2; exit 1 ;; esac
    done
    if [ "$storage_mode" = fixed ]; then
      printf '%s\n' "$storage_volume" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
        || { echo "fixed storage requires an exact Cinder volume UUID" >&2; exit 1; }
      cat <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${storage_pv}
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  capacity: {storage: ${storage_size}Gi}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${storage_class}
  csi:
    driver: cinder.csi.openstack.org
    volumeHandle: ${storage_volume}
---
EOF
    fi
    cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${storage_claim}
  namespace: ${ARGOCD_APP_DEST_NAMESPACE}
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ${storage_class}
  resources: {requests: {storage: ${storage_size}Gi}}
EOF
    if [ "$storage_mode" = fixed ]; then
      printf '  volumeName: %s\n' "$storage_pv"
    fi
    ;;
  secrets)
    case "$config_path" in *.sops.yaml|*.sops.yml) ;; *) echo "secret input must be a SOPS YAML file" >&2; exit 1 ;; esac
    output=$(mktemp /tmp/csoc-secret.XXXXXX.yaml)
    trap 'rm -f -- "$output"' EXIT HUP INT TERM
    sops --decrypt "$config_path" >"$output"
    expected=${ARGOCD_ENV_EXPECTED_SECRETS:-}
    old_ifs=$IFS; IFS=,
    for secret_name in $expected; do
      yq -e "select(.kind == \"Secret\" and .metadata.name == \"${secret_name}\")" "$output" >/dev/null \
        || { echo "expected Secret missing from bundle: ${secret_name}" >&2; exit 1; }
    done
    IFS=$old_ifs
    cat "$output"
    ;;
  addon)
    echo "optional addon delivery is blocked until its artifact and renderer pass acceptance" >&2
    exit 1
    ;;
  kustomize)
    reject_remote_kustomize_sources
    kustomize build "$config_path"
    ;;
  helm)
    chart=${ARGOCD_ENV_HELM_CHART:-}
    version=${ARGOCD_ENV_HELM_VERSION:-}
    case "${chart}:${version}" in
      jupyterhub/jupyterhub:4.3.4) chart_file=/opt/csoc/charts/jupyterhub-4.3.4.tgz ;;
      prometheus-community/kube-prometheus-stack:84.3.0) chart_file=/opt/csoc/charts/kube-prometheus-stack-84.3.0.tgz ;;
      jupyter-jsc/jupyterhub-outpost:2.1.2)
        chart_file=/opt/csoc/charts/jupyterhub-outpost-2.1.2.tgz
        [ -f "$chart_file" ] || { echo "pinned Outpost 2.1.2 archive is not published by the upstream repository" >&2; exit 1; }
        ;;
      csoc/registry-cache:0.1.0) chart_file=projects/community/charts/registry-cache; chart_kind=registry ;;
      *) echo "chart/version is not embedded or allowlisted: ${chart}:${version}" >&2; exit 1 ;;
    esac
    [ -f "${config_path}/helm-values.txt" ] || { echo "missing helm-values.txt" >&2; exit 1; }
    work_dir=$(mktemp -d /tmp/csoc-helm.XXXXXX)
    trap 'rm -rf -- "$work_dir"' EXIT HUP INT TERM
    set --
    while IFS= read -r values_file; do
      case "$values_file" in ''|'#'*) continue ;; /*|*..*) echo "invalid values path: $values_file" >&2; exit 1 ;; esac
      source_file="${config_path}/${values_file}"
      [ -f "$source_file" ] || { echo "missing values file: $source_file" >&2; exit 1; }
      rendered_file="${work_dir}/$(basename "$values_file")"
      case "$source_file" in *.sops.yaml|*.sops.yml) sops --decrypt "$source_file" >"$rendered_file" ;; *) cp "$source_file" "$rendered_file" ;; esac
      set -- "$@" -f "$rendered_file"
    done <"${config_path}/helm-values.txt"
    if [ "${chart_kind:-}" = registry ]; then
      registry_type=${ARGOCD_ENV_REGISTRY_STORAGE_TYPE:-}
      case "$registry_type" in filesystem|s3) ;; *) echo "registry storage type must be filesystem or s3" >&2; exit 1 ;; esac
      set -- "$@" --set-string "storage.type=${registry_type}"
      if [ "$registry_type" = filesystem ]; then
        registry_claim=${ARGOCD_ENV_REGISTRY_CLAIM_NAME:-}
        case "$registry_claim" in ''|*[!a-z0-9-]*) echo "invalid registry Cinder claim name" >&2; exit 1 ;; esac
        set -- "$@" --set-string "persistence.existingClaim=${registry_claim}"
      else
        registry_bucket=${ARGOCD_ENV_REGISTRY_S3_BUCKET:-}
        registry_endpoint=${ARGOCD_ENV_REGISTRY_S3_ENDPOINT:-}
        case "$registry_bucket" in ''|*[!a-z0-9.-]*) echo "invalid registry S3 bucket" >&2; exit 1 ;; esac
        case "$registry_endpoint" in https://*) ;; *) echo "registry S3 endpoint must use HTTPS" >&2; exit 1 ;; esac
        set -- "$@" --set-string "storage.s3.bucket=${registry_bucket}" --set-string "storage.s3.regionEndpoint=${registry_endpoint}"
      fi
    fi
    include_crds=
    case "${chart}:${version}" in
      jupyterhub/jupyterhub:4.3.4)
        auth_mode=${ARGOCD_ENV_JUPYTERHUB_AUTH_MODE:-}
        endpoint_placement=${ARGOCD_ENV_ENDPOINT_PLACEMENT:-}
        tls_mode=${ARGOCD_ENV_TLS_MODE:-}
        hub_db_class=${ARGOCD_ENV_HUB_DB_STORAGE_CLASS:-}
        hub_db_size=${ARGOCD_ENV_HUB_DB_SIZE_GIB:-}
        home_class=${ARGOCD_ENV_HOME_STORAGE_CLASS:-}
        home_size=${ARGOCD_ENV_HOME_SIZE_GIB:-}
        [ "$auth_mode" = dummy ] || { echo "only dummy JupyterHub authentication is currently supported" >&2; exit 1; }
        [ "$endpoint_placement" = clusterIP ] || { echo "only ClusterIP JupyterHub endpoints are currently supported" >&2; exit 1; }
        [ "$tls_mode" = none ] || { echo "JupyterHub TLS modes remain blocked pending live acceptance" >&2; exit 1; }
        [ -z "${ARGOCD_ENV_ENDPOINT_ALLOWED_CIDR:-}${ARGOCD_ENV_ENDPOINT_HOSTNAME:-}${ARGOCD_ENV_TLS_SECRET_NAME:-}" ] \
          || { echo "ClusterIP/no-TLS JupyterHub must not set CIDR, hostname, or TLS secret" >&2; exit 1; }
        [ "$hub_db_class" = cinder-retain ] && [ "$home_class" = cinder-retain ] \
          || { echo "JupyterHub storage must use cinder-retain" >&2; exit 1; }
        case "$hub_db_size:$home_size" in *[!0-9:]*|:*|*:) echo "invalid JupyterHub storage size" >&2; exit 1 ;; esac
        [ "$hub_db_size" -ge 1 ] && [ "$home_size" -ge 1 ] \
          || { echo "JupyterHub storage sizes must be positive" >&2; exit 1; }
        set -- "$@" \
          --set-string hub.config.JupyterHub.authenticator_class=dummy \
          --set hub.config.Authenticator.allow_all=true \
          --set-string proxy.service.type=ClusterIP \
          --set proxy.https.enabled=false \
          --set-string hub.db.pvc.storageClassName="$hub_db_class" \
          --set-string hub.db.pvc.storage="${hub_db_size}Gi" \
          --set-string singleuser.storage.dynamic.storageClass="$home_class" \
          --set-string singleuser.storage.capacity="${home_size}Gi"
        ;;
      prometheus-community/kube-prometheus-stack:84.3.0)
        grafana=${ARGOCD_ENV_MONITORING_GRAFANA_ENABLED:-}
        alertmanager=${ARGOCD_ENV_MONITORING_ALERTMANAGER_ENABLED:-}
        prometheus_class=${ARGOCD_ENV_PROMETHEUS_STORAGE_CLASS:-}
        prometheus_size=${ARGOCD_ENV_PROMETHEUS_STORAGE_SIZE_GIB:-}
        case "$grafana:$alertmanager" in true:true|true:false|false:true|false:false) ;; *) echo "monitoring feature flags must be booleans" >&2; exit 1 ;; esac
        [ "$prometheus_class" = cinder-retain ] || { echo "Prometheus storage must use cinder-retain" >&2; exit 1; }
        case "$prometheus_size" in ''|*[!0-9]*) echo "invalid Prometheus storage size" >&2; exit 1 ;; esac
        [ "$prometheus_size" -ge 1 ] || { echo "Prometheus storage size must be positive" >&2; exit 1; }
        set -- "$@" \
          --set "grafana.enabled=${grafana}" \
          --set "alertmanager.enabled=${alertmanager}" \
          --set-string prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName="$prometheus_class" \
          --set-string prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage="${prometheus_size}Gi"
        include_crds=--include-crds
        ;;
    esac
    helm template "${ARGOCD_APP_NAME}" "$chart_file" --namespace "${ARGOCD_APP_DEST_NAMESPACE}" ${include_crds} "$@"
    ;;
  *) echo "unsupported CMP mode: ${mode}" >&2; exit 1 ;;
esac
