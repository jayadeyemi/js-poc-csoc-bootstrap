#!/usr/bin/env bash
# Deterministic kubectl fake for all-spoke registration tests.
set -euo pipefail

args="$*"
printf '%s\n' "${args}" >>"${FAKE_KUBECTL_LOG:?FAKE_KUBECTL_LOG is required}"

spoke_name=''
[[ "${args}" == *spoke-good* ]] && spoke_name=spoke-good
[[ "${args}" == *spoke-bad* ]] && spoke_name=spoke-bad

case "${args}" in
  "get spokecluster --all-namespaces "*)
    printf 'spokeclusters\tspoke-good\nspokeclusters\tspoke-bad\n'
    ;;
  get\ spokecluster\ *"jsonpath={.spec.registration.enabled}"*) printf 'true' ;;
  get\ spokecluster\ *"jsonpath={.status.ready}"*) printf 'true' ;;
  get\ spokecluster\ *"jsonpath={.status.endpoint}"*) printf '%s.example:6443' "${spoke_name#spoke-}" ;;
  get\ spokecluster\ *"jsonpath={.spec.controlPlane.count}"*) printf '1' ;;
  get\ spokecluster\ *"jsonpath={.spec.kubernetes.minNodes}"*) printf '2' ;;
  get\ spokecluster\ *"csoc.js2.org/customer"*) printf 'poc-tenant' ;;
  get\ spokecluster\ *"csoc.js2.org/environment"*) printf 'dev' ;;
  get\ spokecluster\ *"csoc.js2.org/ownership"*) printf 'csoc' ;;
  get\ spokecluster\ *"csoc.js2.org/hello-csoc"*) printf 'enabled' ;;
  get\ spokecluster\ *"jsonpath={.spec.capabilities.security}"*) printf 'false' ;;
  get\ spokecluster\ *"jsonpath={.spec.capabilities.observability}"*) printf 'false' ;;
  get\ secret\ spoke-*-kubeconfig\ *"jsonpath={.data.value}"*)
    printf 'test-kubeconfig-%s' "${spoke_name}" | base64 | tr -d '\n'
    ;;
  *"config view --minify --raw -o jsonpath={.clusters[0].cluster.server}"*)
    printf 'https://%s.example:6443' "${spoke_name#spoke-}"
    ;;
  *"get --raw=/readyz"*)
    if [[ "${spoke_name}" == spoke-bad && "${FAKE_ALL_REACHABLE:-false}" != true ]]; then
      exit 1
    fi
    printf 'ok\n'
    ;;
  *"auth can-i list nodes"*) printf 'yes\n' ;;
  *"get nodes -o jsonpath="*)
    printf 'control\tTrue\tnode-role.kubernetes.io/control-plane,\nworker-1\tTrue\t\nworker-2\tTrue\t\n'
    ;;
  *"jsonpath={.clusters[0].cluster.server}"*"--raw") printf 'https://%s.example:6443' "${spoke_name#spoke-}" ;;
  *"jsonpath={.clusters[0].cluster.certificate-authority-data}"*) printf 'Q0E=' ;;
  *"jsonpath={.users[0].user.client-certificate-data}"*) printf 'Q0VSVA==' ;;
  *"jsonpath={.users[0].user.client-key-data}"*) printf 'S0VZ' ;;
  create\ secret\ generic\ cluster-*)
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: rendered-test-secret\n'
    ;;
  "apply --server-side -f -") cat >/dev/null ;;
  label\ secret\ cluster-*|annotate\ secret\ cluster-*) ;;
  "get secret cluster-spoke-bad -n argocd")
    [[ "${FAKE_EXISTING_BAD_REGISTRATION:-true}" == true ]]
    ;;
  "get secret cluster-spoke-good -n argocd") exit 1 ;;
  *)
    printf 'Unhandled registration fake kubectl command: %s\n' "${args}" >&2
    exit 64
    ;;
esac
