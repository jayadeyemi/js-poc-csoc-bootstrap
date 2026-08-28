#!/usr/bin/env bash
# Prove KRO aggregation covers every v2 generated or referenced GVK without wildcards.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CATALOG_ROOT="${REPO_ROOT}/../js-poc-csoc-app-catalog"
ROLE="${REPO_ROOT}/controllers/kro-v2-rbac.yaml"

role_json=$(yq -o=json '.' "${ROLE}")
jq -e '
  .metadata.labels["rbac.kro.run/aggregate-to-controller"] == "true" and
  ([.rules[] | .apiGroups[], .resources[], .verbs[]] | all(. != "*"))
' <<<"${role_json}" >/dev/null || {
  echo "KRO v2 aggregation role is missing its label or contains a wildcard" >&2
  exit 1
}

plural() {
  case "$1" in
    Namespace) echo namespaces ;;
    ConfigMap) echo configmaps ;;
    ResourceQuota) echo resourcequotas ;;
    AppProject) echo appprojects ;;
    RouterInterface) echo routerinterfaces ;;
    VolumeType) echo volumetypes ;;
    OpenStackClusterIdentity) echo openstackclusteridentities ;;
    KubeadmConfigTemplate) echo kubeadmconfigtemplates ;;
    KubeadmControlPlane) echo kubeadmcontrolplanes ;;
    *y) printf '%s' "${1%y}" | tr '[:upper:]' '[:lower:]'; echo ies ;;
    *) printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; echo s ;;
  esac
}

while IFS="$(printf '\t')" read -r api_version kind; do
  [[ -n "${kind}" ]] || continue
  case "${api_version}" in */*) group=${api_version%/*} ;; *) group= ;; esac
  resource=$(plural "${kind}")
  jq -e --arg group "${group}" --arg resource "${resource}" '
    any(.rules[]; (.apiGroups | index($group)) != null and (.resources | index($resource)) != null and
      ((.verbs | index("get")) != null) and ((.verbs | index("watch")) != null))
  ' <<<"${role_json}" >/dev/null || {
    echo "KRO v2 aggregation role does not cover ${api_version} ${kind} (${resource})" >&2
    exit 1
  }
done < <(
  for rgd in "${CATALOG_ROOT}"/rgds/v2/{infrastructure,bindings,services}/*.yaml; do
    yq -r '.spec.resources[] | ((.template // .externalRef).apiVersion + "\t" + (.template // .externalRef).kind)' "${rgd}"
  done | sort -u
)

while IFS="$(printf '\t')" read -r group resource; do
  jq -e --arg group "${group}" --arg resource "${resource}/status" '
    any(.rules[]; (.apiGroups | index($group)) != null and (.resources | index($resource)) != null and
      ((.verbs | index("update")) != null) and ((.verbs | index("patch")) != null))
  ' <<<"${role_json}" >/dev/null || {
    echo "KRO v2 aggregation role does not cover generated API status ${group}/${resource}" >&2
    exit 1
  }
done < <(
  for rgd in "${CATALOG_ROOT}"/rgds/v2/{infrastructure,bindings,services}/*.yaml; do
    [[ $(yq -r '.kind' "${rgd}") == ResourceGraphDefinition ]] || continue
    group=$(yq -r '.spec.schema.group' "${rgd}")
    kind=$(yq -r '.spec.schema.kind' "${rgd}")
    printf '%s\t%s\n' "${group}" "$(plural "${kind}")"
  done | sort -u
)

echo "KRO v2 aggregation GVK inventory is explicit and complete"
