---
description: >
  End-to-end application verification on poc-tenant-dev. Confirms that ArgoCD
  ApplicationSets deployed the baseline (namespaces, network-policies) and
  hello-csoc (nginx deployment + service) to the spoke. Tests a Cinder-backed
  PVC to prove the storage stack works. Final gate for the POC.
tools:
  - run_in_terminal
---

# Spoke Application Deployment Verification

**Prerequisite:** Agent 06 completed — `cluster-poc-tenant-dev` Argo secret
exists with `csoc.js2.org/reachable=true` and labels including `hello-csoc=enabled`.

## Container invocation pattern

```bash
cd /mnt/c/Users/boadeyem/Jetstream2-CSOC-POC/js-poc-csoc-bootstrap
KDIR="$(pwd)/.state/kubeconfigs"
```

Spoke kubeconfig is at `.state/kubeconfigs/poc-tenant-dev.yaml`.
Inside the container it is at `/home/jetstream/.kube/poc-tenant-dev.yaml`.

Define a shorthand for running spoke-targeted kubectl:
```bash
spoke() {
  KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
    kubectl --kubeconfig /home/jetstream/.kube/poc-tenant-dev.yaml "$@"
}
```

## Step 1 — Verify ApplicationSets targeted the spoke

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  echo "=== ApplicationSets ===" &&
  kubectl get applicationsets -n argocd &&
  echo &&
  echo "=== Applications for poc-tenant-dev ===" &&
  kubectl get applications -n argocd | grep poc-tenant-dev || echo "none yet"
'
```

Expected ApplicationSets from `argocd/applicationsets/`:
- `spoke-baseline`
- `spoke-apps` (hello-csoc)
- `spoke-observability` (capabilities.observability=false → skipped)
- `spoke-security` (capabilities.security=false → skipped)

Expected Applications targeting the spoke:
- `poc-tenant-dev-baseline` (Synced Healthy)
- `poc-tenant-dev-hello-csoc` (Synced Healthy)

If applications are absent: the cluster secret labels may not have propagated yet.
Wait 2–3 minutes for the ApplicationSet controller to re-evaluate.

## Step 2 — Verify baseline application on the spoke

```bash
spoke kubectl get namespaces | grep -E "csoc-system|csoc-monitoring|csoc-security"
```

Expected: all three namespaces `Active`.

```bash
spoke kubectl get networkpolicies -A
```

Expected: `default-deny-ingress` in `csoc-system` and `csoc-security`,
`allow-intra-namespace` in `csoc-monitoring`.

## Step 3 — Verify hello-csoc deployment

```bash
spoke kubectl get all -n hello-csoc
```

Expected:
- Deployment `hello-csoc` with 2/2 Ready replicas
- ReplicaSet with 2 current pods
- Service `hello-csoc` with `ClusterIP`
- Both pods `Running`

Check pod readiness probes have passed:
```bash
spoke kubectl get pods -n hello-csoc \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
```

Expected: both pods show `True`.

## Step 4 — Smoke-test the hello-csoc HTTP endpoint

From inside the container, use `kubectl exec` to curl the service from a pod
in `default` namespace, or use port-forward:

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  kubectl --kubeconfig /home/jetstream/.kube/poc-tenant-dev.yaml \
    run curl-test --rm -i --restart=Never \
    --image=curlimages/curl:8.9.1 \
    --namespace hello-csoc \
    -- curl -s -o /dev/null -w "%{http_code}" http://hello-csoc.hello-csoc.svc.cluster.local/
'
```

Expected: HTTP status `200`.

## Step 5 — Test Cinder-backed PVC

Apply a test PVC directly to the spoke to verify Cinder CSI is functional:

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
cat <<EOF | kubectl --kubeconfig /home/jetstream/.kube/poc-tenant-dev.yaml apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cinder-smoke-test
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: cinder-csi
  resources:
    requests:
      storage: 1Gi
EOF
'
```

Wait for `Bound` (up to 3 minutes):

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  kubectl --kubeconfig /home/jetstream/.kube/poc-tenant-dev.yaml \
    wait pvc cinder-smoke-test -n default \
    --for=jsonpath="{.status.phase}"=Bound \
    --timeout=180s && echo "PVC Bound"
'
```

Delete the test PVC:

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl --kubeconfig /home/jetstream/.kube/poc-tenant-dev.yaml \
    delete pvc cinder-smoke-test -n default
```

## Step 6 — Final ArgoCD Application status

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl get applications -n argocd \
    -o custom-columns="NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status"
```

Expected: every Application shows `Synced` and `Healthy`.

## Step 7 — Full end-to-end summary

Run this to produce a final status table:

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  echo "=== Management cluster nodes ==="
  kubectl get nodes -o wide
  echo ""
  echo "=== ArgoCD Applications ==="
  kubectl get applications -n argocd \
    -o custom-columns="APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status"
  echo ""
  echo "=== SpokeCluster status ==="
  kubectl get spokecluster -n spokeclusters \
    -o custom-columns="NAME:.metadata.name,READY:.status.ready,PHASE:.status.phase,ENDPOINT:.status.endpoint"
  echo ""
  echo "=== Argo cluster secrets ==="
  kubectl get secret -n argocd \
    -l argocd.argoproj.io/secret-type=cluster \
    -o custom-columns="SECRET:.metadata.name,REACHABLE:.metadata.annotations.csoc\.js2\.org/reachable"
'
```

And from the spoke:
```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  echo "=== Spoke nodes ==="
  kubectl --kubeconfig /home/jetstream/.kube/poc-tenant-dev.yaml get nodes -o wide
  echo ""
  echo "=== Spoke hello-csoc pods ==="
  kubectl --kubeconfig /home/jetstream/.kube/poc-tenant-dev.yaml get pods -n hello-csoc -o wide
'
```

## Pass criteria

| Check | Expected |
|---|---|
| `spoke-baseline` Application | Synced Healthy |
| `spoke-hello-csoc` Application | Synced Healthy |
| `csoc-system` namespace on spoke | Active |
| `csoc-monitoring` namespace on spoke | Active |
| `csoc-security` namespace on spoke | Active |
| `default-deny-ingress` NetworkPolicies | present in csoc-system, csoc-security |
| `hello-csoc` Deployment | 2/2 Ready |
| HTTP 200 from hello-csoc service | pass |
| Cinder PVC `Bound` | pass |
| All ArgoCD Applications | Synced Healthy |

**POC end-to-end validated.** Git is the control plane. Adding a new spoke cluster
is a PR to `js-poc-csoc-fleet`.
