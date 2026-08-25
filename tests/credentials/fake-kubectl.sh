#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${FAKE_KUBECTL_LOG:?FAKE_KUBECTL_LOG is required}"
state_dir=${FAKE_KUBECTL_STATE:?FAKE_KUBECTL_STATE is required}
mkdir -p "${state_dir}"

case "$*" in
  get\ namespace\ *)
    namespace=$3
    [[ -f "${state_dir}/${namespace}" ]]
    ;;
  create\ namespace\ *)
    namespace=$3
    : >"${state_dir}/${namespace}"
    printf 'namespace/%s created\n' "${namespace}"
    ;;
  label\ namespace\ *)
    printf 'namespace labeled\n'
    ;;
  create\ secret\ generic\ *)
    name=$4
    namespace=default
    previous=
    for argument in "$@"; do
      if [[ "${previous}" == --namespace ]]; then namespace=${argument}; fi
      if [[ "${argument}" == --namespace=* ]]; then namespace=${argument#--namespace=}; fi
      previous=${argument}
    done
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata: {}\n' \
      "${name}" "${namespace}"
    ;;
  apply\ --server-side\ -f\ -)
    while IFS= read -r _; do :; done
    printf 'secret applied\n'
    ;;
  *) printf 'Unhandled fake kubectl command: %s\n' "$*" >&2; exit 64 ;;
esac
