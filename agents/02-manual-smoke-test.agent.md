---
description: >
  Manual smoke test before committing to ArgoCD. Installs cert-manager via Helm
  directly (no ArgoCD), verifies CRDs establish, runs dry-run server-side apply
  on the App-of-Apps and AppProject manifests, then cleans up. Proves the
  management cluster can run controllers and that GitOps manifests are valid.
tools:
  - run_in_terminal
  - read_file
---

# Manual Smoke Test (Pre-ArgoCD Gate)

**Why this exists:** ArgoCD will install cert-manager, KRO, CAPI, CAPO, and
others as its first reconciliation pass. Before handing control to ArgoCD, this
agent verifies the Helm install path works and the GitOps manifests are
server-valid — without permanently installing anything.

**Gate:** Pass all four checks before running agent 03.

## Container invocation pattern

```bash
cd /mnt/c/Users/boadeyem/Jetstream2-CSOC-POC/js-poc-csoc-bootstrap
KDIR="$(pwd)/.state/kubeconfigs"
```

All commands below are prefixed `KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh`.

## Step 1 — Helm install: cert-manager (trial run)

Install the exact version ArgoCD will later install (`CERT_MANAGER_VERSION=1.21.1`):

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  helm repo add jetstack https://charts.jetstack.io --force-update &&
  helm repo update &&
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --version 1.21.1 \
    --set crds.enabled=true \
    --create-namespace \
    --wait \
    --timeout 5m
'
```

Expected: `Release "cert-manager" has been upgraded. Happy Helming!`

## Step 2 — Verify CRDs established

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  for crd in certificates.cert-manager.io certificaterequests.cert-manager.io \
             clusterissuers.cert-manager.io issuers.cert-manager.io; do
    kubectl wait crd "$crd" --for=condition=Established --timeout=120s \
      && echo "OK: $crd" || echo "FAIL: $crd"
  done
'
```

Expected: all 4 print `OK:`.

## Step 3 — Dry-run server-side apply of ArgoCD manifests

With cert-manager CRDs present, the server can now validate any manifest that
references them. Run a dry-run on the AppProject files and the App-of-Apps:

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  kubectl apply --dry-run=server --server-side \
    -f argocd/projects/csoc-platform.yaml \
    -f argocd/projects/csoc-fleet.yaml \
    -f argocd/projects/csoc-baseline.yaml &&
  echo "AppProjects: OK"
'
```

Expected output contains `configured (server dry run)` or `created (server dry run)` for each file.

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  kubectl apply --dry-run=server --server-side \
    -f argocd/app-of-apps.yaml -n argocd 2>&1 || true
'
```

Expected: either `created (server dry run)` or a validation error about the `argocd`
namespace not existing (acceptable — ArgoCD does not exist yet). Any other error
(schema violation, bad field) is a real failure and must be fixed before continuing.

## Step 4 — Clean up cert-manager trial install

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  helm uninstall cert-manager --namespace cert-manager --wait --timeout 3m &&
  kubectl delete namespace cert-manager --ignore-not-found=true --timeout=60s
'
```

Expected: `release "cert-manager" uninstalled` and namespace gone.

Verify clean:

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  kubectl get namespace cert-manager 2>&1 || echo "absent (expected)"
  kubectl get crd | grep cert-manager || echo "no cert-manager CRDs (expected)"
'
```

Expected: namespace absent, CRDs absent.

## Pass criteria

| Check | Expected |
|---|---|
| cert-manager Helm install | exits 0, pods Running |
| 4 cert-manager CRDs | all Established |
| AppProject dry-run | no schema errors |
| App-of-Apps dry-run | schema valid (namespace-absent error OK) |
| cert-manager removed | namespace + CRDs gone |

All pass → management cluster is confirmed ready for agent 03.
