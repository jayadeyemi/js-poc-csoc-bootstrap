---
description: >
  Verify the cluster-registration CronJob has registered poc-tenant-dev with
  ArgoCD, that the Argo cluster secret exists with reachability annotations set,
  and that the spoke is listed in ArgoCD as a managed cluster.
tools:
  - run_in_terminal
---

# Spoke Registration

**Prerequisite:** Agent 05 completed — `poc-tenant-dev` SpokeCluster is Ready.
The cluster-registration CronJob runs every 2 minutes automatically.

## Container invocation pattern

```bash
cd /mnt/c/Users/boadeyem/Jetstream2-CSOC-POC/js-poc-csoc-bootstrap
KDIR="$(pwd)/.state/kubeconfigs"
```

## Step 1 — Verify the cluster-registration CronJob exists

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl get cronjob,deployment,serviceaccount -n cluster-registration
```

Expected:
- CronJob `cluster-registration` (schedule `*/2 * * * *`)
- No deployment (the CronJob is the only workload)

## Step 2 — Check recent Jobs

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl get jobs -n cluster-registration \
    --sort-by=.metadata.creationTimestamp
```

Expected: at least one Job in `Complete` state after the SpokeCluster became Ready.
If no jobs exist yet, the CronJob has not fired since bootstrap — wait up to 2 minutes.

Check the most recent Job's log:
```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  job=$(kubectl get jobs -n cluster-registration \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath="{.items[-1].metadata.name}" 2>/dev/null)
  [[ -n "$job" ]] && kubectl logs -n cluster-registration "job/$job" || echo "no jobs yet"
'
```

Expected log lines:
- `[registration] Starting cluster registration pass`
- `[registration] poc-tenant-dev: registered` (or `updated`)

## Step 3 — Verify the Argo cluster secret was created

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl get secret cluster-poc-tenant-dev -n argocd \
    -o jsonpath='{.metadata.labels}{"\n"}{.metadata.annotations}' 2>/dev/null \
  && echo "" || echo "secret not yet created"
```

Expected labels: `argocd.argoproj.io/secret-type=cluster`.
Expected annotations:
- `csoc.js2.org/reachable: "true"`
- `csoc.js2.org/reachability-checked-at: <timestamp>`

## Step 4 — List all registered clusters in ArgoCD

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  kubectl get secret -n argocd \
    -l argocd.argoproj.io/secret-type=cluster \
    -o custom-columns="NAME:.metadata.name,REACHABLE:.metadata.annotations.csoc\.js2\.org/reachable,CHECKED:.metadata.annotations.csoc\.js2\.org/reachability-checked-at"
'
```

Expected: `cluster-poc-tenant-dev` with `REACHABLE=true`.

## Step 5 — Verify with argocd CLI (optional)

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)
  argocd login localhost:443 \
    --username admin \
    --password "$ARGOCD_PASS" \
    --insecure \
    --grpc-web \
    --port-forward \
    --port-forward-namespace argocd 2>/dev/null &&
  argocd cluster list
'
```

Expected: `poc-tenant-dev` cluster appears in the list with a `https://<ip>:6443` server.

## Step 6 — Confirm registration labels on the cluster secret

The registration CronJob copies `spec.registration.labels` from the SpokeCluster
into the Argo cluster secret. Verify:

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl get secret cluster-poc-tenant-dev -n argocd \
    -o jsonpath='{.metadata.labels}' | jq .
```

Expected labels include:
- `csoc.js2.org/customer: poc-tenant`
- `csoc.js2.org/environment: dev`
- `csoc.js2.org/hello-csoc: enabled`

These labels drive the ApplicationSets in agent 07.

## Failure guidance

**Job completes but secret not created:**
The registration script requires the SpokeCluster's status endpoint to be set
and `spec.registration.enabled: true`. Check:
```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl get spokecluster poc-tenant-dev -n spokeclusters \
    -o jsonpath='{.status.endpoint} {.status.ready} {.spec.registration.enabled}{"\n"}'
```

**Reachability check fails (REACHABLE=false):**
The registration CronJob runs `confirm-reachability.sh` against the spoke API.
Check network connectivity from the management cluster to the spoke API IP.
The spoke API address comes from `status.endpoint`.

**Jobs consistently fail:**
```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl describe job -n cluster-registration \
    $(kubectl get jobs -n cluster-registration \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath="{.items[-1].metadata.name}")
```

## Pass criteria

| Check | Expected |
|---|---|
| CronJob exists | `*/2 * * * *` schedule |
| At least one Job | `Complete` status |
| Job log | `poc-tenant-dev: registered` |
| Argo cluster secret | present with `secret-type=cluster` |
| Reachability annotation | `csoc.js2.org/reachable=true` |
| Registration labels | `hello-csoc=enabled`, `customer=poc-tenant` |

Proceed to **07-spoke-apps**.
