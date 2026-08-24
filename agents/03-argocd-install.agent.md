---
description: >
  Install ArgoCD via Helm on the management cluster using the pinned chart
  version (10.4.0) and the existing iac/argocd/values.yaml. Verify the server
  deployment is Available and all pods are Running. Produces no secrets in Git.
tools:
  - run_in_terminal
---

# ArgoCD Installation

**Prerequisite:** Agent 01 (health check) passed. Agent 02 (smoke test) recommended.
**Gate:** `argocd-server` deployment Available before proceeding to agent 04.

## Container invocation pattern

```bash
cd /mnt/c/Users/boadeyem/Jetstream2-CSOC-POC/js-poc-csoc-bootstrap
KDIR="$(pwd)/.state/kubeconfigs"
```

## Step 1 — Install ArgoCD via Helm

The existing script handles everything: namespace, Helm repo, version pin, values:

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  bash scripts/bootstrap/argocd/install.sh
```

This runs `helm upgrade --install argocd argo/argo-cd --version 10.4.0 --wait --timeout 10m`.
Expected: script prints `[SUCCESS] Argo CD installed.`

If it times out, check pod events:
```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl get pods -n argocd
```

## Step 2 — Verify all ArgoCD pods are Running

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  kubectl get pods -n argocd &&
  kubectl get deployment argocd-server -n argocd \
    -o jsonpath="{.status.availableReplicas}" &&
  echo ""
'
```

Expected pods (all `1/1 Running`):
- `argocd-application-controller-*`
- `argocd-applicationset-controller-*`
- `argocd-dex-server-*`
- `argocd-notifications-controller-*`
- `argocd-redis-*`
- `argocd-repo-server-*`
- `argocd-server-*`

## Step 3 — Record the initial admin password retrieval command

Do NOT print the password itself. The password is a one-time bootstrap secret.
To retrieve it later, run inside the container:

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  argocd admin initial-password -n argocd
```

Or directly with kubectl:
```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d && echo
```

Store the password in a local password manager. The secret should be deleted
after the first login and password change.

## Step 4 — Confirm UI access (optional)

To access the ArgoCD UI, start a port-forward from the host (not inside the container):

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  kubectl -n argocd port-forward svc/argocd-server 8443:443
'
```

Then open `https://localhost:8443` in a browser (accept the self-signed cert).
Login with username `admin` and the password from step 3.

## Step 5 — Verify ArgoCD server service exists

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl get svc -n argocd
```

Expected: `argocd-server` service with `ClusterIP`.

## Pass criteria

| Check | Expected |
|---|---|
| install script exit code | 0 |
| `argocd-server` deployment | Available=1 |
| all ArgoCD pods | 1/1 Running |
| initial-admin-secret | exists |
| argocd namespace | present with correct services |

Proceed to **04-argocd-bootstrap** immediately — do not leave ArgoCD installed
without running the bootstrap, as it will be idle without any AppProjects or Applications.
