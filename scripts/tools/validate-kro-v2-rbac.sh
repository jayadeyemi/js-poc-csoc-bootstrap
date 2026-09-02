#!/usr/bin/env bash
# Prove KRO aggregation covers every generated or referenced GVK without wildcards.
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

# Kubernetes prevents a service account from creating a Role that grants
# permissions it does not itself hold. The v1 spoke graph delegates these
# namespace-scoped CAPI permissions to each spoke autoscaler.
for resource in machinedeployments machinedeployments/scale machines machinesets machinepools; do
  for verb in get list watch update patch; do
    jq -e --arg resource "${resource}" --arg verb "${verb}" '
      any(.rules[]; (.apiGroups | index("cluster.x-k8s.io")) != null and
        (.resources | index($resource)) != null and (.verbs | index($verb)) != null)
    ' <<<"${role_json}" >/dev/null || {
      echo "KRO aggregation role cannot delegate ${verb} on cluster.x-k8s.io/${resource}" >&2
      exit 1
    }
  done
done

plural() {
  case "$1" in
    Namespace) echo namespaces ;;
    ConfigMap) echo configmaps ;;
    Secret) echo secrets ;;
    Service) echo services ;;
    ServiceAccount) echo serviceaccounts ;;
    ResourceQuota) echo resourcequotas ;;
    Deployment) echo deployments ;;
    Role) echo roles ;;
    RoleBinding) echo rolebindings ;;
    AppProject) echo appprojects ;;
    RouterInterface) echo routerinterfaces ;;
    VolumeType) echo volumetypes ;;
    KeyPair) echo keypairs ;;
    SecurityGroup) echo securitygroups ;;
    ServerGroup) echo servergroups ;;
    SpokeGitOps) echo spokegitops ;;
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
  while IFS= read -r -d '' rgd; do
    yq -r '.spec.resources[] | ((.template // .externalRef).apiVersion + "\t" + (.template // .externalRef).kind)' "${rgd}"
  done < <(find "${CATALOG_ROOT}/rgds" -type f -name '*.rgd*.yaml' -print0) | sort -u
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
  while IFS= read -r -d '' rgd; do
    [[ $(yq -r '.kind' "${rgd}") == ResourceGraphDefinition ]] || continue
    group=$(yq -r '.spec.schema.group' "${rgd}")
    kind=$(yq -r '.spec.schema.kind' "${rgd}")
    printf '%s\t%s\n' "${group}" "$(plural "${kind}")"
  done < <(find "${CATALOG_ROOT}/rgds" -type f -name '*.rgd*.yaml' -print0) | sort -u
)

echo "KRO dual-generation aggregation GVK inventory is explicit and complete"
