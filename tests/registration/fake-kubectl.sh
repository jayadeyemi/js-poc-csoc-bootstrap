#!/usr/bin/env bash
set -euo pipefail

joined=" $* "
printf '%s\n' "$*" >>"${FAKE_KUBECTL_LOG}"

if [[ "${joined}" == *" apply -f - "* || "${joined}" == *" apply --server-side -f - "* ]]; then
  input=$(sed -n '1,240p')
  printf '%s\n' "${input}" >>"${FAKE_KUBECTL_LOG}"
  exit 0
fi
if [[ "${joined}" == *" create secret generic "* ]]; then
  name=${joined#* create secret generic }
  name=${name%% *}
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n' "${name}"
  exit 0
fi
if [[ "${joined}" == *" config "* ]]; then
  kubeconfig=
  previous=
  for argument in "$@"; do
    if [[ "${previous}" == --kubeconfig ]]; then kubeconfig=${argument}; fi
    case "${argument}" in --kubeconfig=*) kubeconfig=${argument#*=} ;; esac
    previous=${argument}
  done
  if [[ "${joined}" == *" view "* ]]; then
    case "${joined}" in
      *"client-certificate-data"*) printf 'ZmFrZWNlcnQ=' ;;
      *"certificate-authority-data"*) printf '%s' "${MANAGEMENT_CA_DATA}" ;;
      *"cluster.server"*) printf '%s' "${MANAGEMENT_SERVER}" ;;
      *) printf '%s' "${MANAGEMENT_SERVER}" ;;
    esac
  else
    [[ -n "${kubeconfig}" ]] && printf 'fake-management-kubeconfig' >"${kubeconfig}"
  fi
  exit 0
fi

if [[ "${joined}" == *" get spokeregistrations --all-namespaces "* ]]; then
  if [[ "${joined}" == *" -o jsonpath="* ]]; then
    printf 'spokeclusters-account\tregistration\n'
  elif [[ "${FAKE_SCENARIO}" == duplicate ]]; then
    printf '%s' '{"items":[{"metadata":{"namespace":"spokeclusters-account"},"spec":{"clusterRef":{"name":"shared"}}},{"metadata":{"namespace":"spokeclusters-account"},"spec":{"clusterRef":{"name":"shared"}}}]}'
  else
    printf '%s' '{"items":[{"metadata":{"namespace":"spokeclusters-account"},"spec":{"clusterRef":{"name":"shared"}}}]}'
  fi
  exit 0
fi
if [[ "${joined}" == *" get spokeregistration registration "* ]]; then
  case "${joined}" in
    *"clusterRef.name"*) printf shared ;;
    *"workloadCloudConfigSecretName"*) printf account-workload-cloud-config ;;
    *"rotationRequest"*) [[ "${FAKE_SCENARIO}" == rotation ]] && printf rotation-1 ;;
    *"deletionTimestamp"*)
      case "${FAKE_SCENARIO}" in cleanup|cleanup-unreachable) printf '2026-08-28T00:00:00Z' ;; esac ;;
    *"metadata.finalizers"*) printf '[registration.csoc.js2.org/credential-protection]' ;;
    *"retirement"*) printf true ;;
    *" -o json "*) printf '%s' '{"metadata":{"finalizers":["registration.csoc.js2.org/credential-protection"]}}' ;;
  esac
  exit 0
fi

if [[ "${joined}" == *" get secret shared-kubeconfig "* ]]; then
  printf 'ZmFrZS1zcG9rZS1rdWJlY29uZmln'
  exit 0
fi
if [[ "${joined}" == *" get secret account-workload-cloud-config "* ]]; then
  if [[ "${joined}" == *"cloud-config"* ]]; then
    cloud_conf=$(printf '[Global]\nauth-url=https://openstack.example/v3\n' | base64 -w0)
    wrapper=$(printf 'apiVersion: v1\nkind: Secret\ndata:\n  cloud.conf: %s\n' "${cloud_conf}")
    printf '%s' "${wrapper}" | base64 -w0
  fi
  exit 0
fi
if [[ "${joined}" == *" get secret cluster-shared"*" -n argocd "* ]]; then
  if [[ "${FAKE_SCENARIO}" == rotation && "${joined}" == *"data.config"* ]]; then
    printf '%s' "{\"tlsClientConfig\":{\"caData\":\"${MANAGEMENT_CA_DATA}\",\"certData\":\"ZmFrZWNlcnQ=\",\"keyData\":\"ZmFrZWtleQ==\"}}" | base64 -w0
    exit 0
  fi
  if [[ "${FAKE_SCENARIO}" == rotation && "${joined}" == *"data.server"* ]]; then
    printf '%s' "${MANAGEMENT_SERVER}" | base64 -w0
    exit 0
  fi
  exit 1
fi
if [[ "${joined}" == *" get secret registration-autoscaler-kubeconfig "* ]]; then
  exit 1
fi
if [[ "${joined}" == *" get csr "* ]]; then
  printf 'ZmFrZWNlcnQ='
  exit 0
fi

if [[ "${joined}" == *" get applicationboundaries "* ]]; then
  if [[ "${joined}" == *" -o jsonpath="* ]]; then
    case "${FAKE_SCENARIO}" in cleanup|cleanup-unreachable) ;; *) printf 'boundary\tshared\tjupyterhub\n' ;; esac
  else
    case "${FAKE_SCENARIO}" in
      cleanup|cleanup-unreachable) printf '%s' '{"items":[]}' ;;
      *) printf '%s' '{"items":[{"metadata":{"name":"boundary"},"status":{"clusterName":"shared"}}]}' ;;
    esac
  fi
  exit 0
fi
if [[ "${joined}" == *" get clusterfoundations "* || "${joined}" == *" get endpointbindings "* ||
      "${joined}" == *" get hubauthbindings "* || "${joined}" == *" get secretbundles "* ||
      "${joined}" == *" get cinderstoragebindings "* || "${joined}" == *" get cephfs"* ||
      "${joined}" == *" get s3"* || "${joined}" == *" get gpuruntimeaddons "* ||
      "${joined}" == *" get smokeapplications "* || "${joined}" == *" get jupyterhubinstances "* ||
      "${joined}" == *" get monitoringinstances "* || "${joined}" == *" get registrycacheinstances "* ||
      "${joined}" == *" get binderbuildinstances "* || "${joined}" == *" get jupyteroutpostinstances "* ]]; then
  printf '%s' '{"items":[]}'
  exit 0
fi
if [[ "${joined}" == *" get applications,appprojects "* ]]; then exit 0; fi
if [[ "${joined}" == *" get --raw=/readyz "* ]]; then
  case "${FAKE_SCENARIO}" in unreachable|cleanup-unreachable) exit 1 ;; *) exit 0 ;; esac
fi

case "${joined}" in
  *" annotate "*|*" patch "*|*" label "*|*" delete "*|*" certificate approve "*) exit 0 ;;
esac

echo "unsupported fake kubectl command: $*" >&2
exit 1
