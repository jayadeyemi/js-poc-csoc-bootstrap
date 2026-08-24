---
description: >
  Create the CAPO OpenStack cloud secrets from runtime-clouds.yaml, then apply
  the App-of-Apps to hand the management cluster to GitOps. Waits for the full
  controller chain: cert-manager → ORC → capi-operator → KRO → CAPI/CAPO CRDs
  → capo-identity → platform-apis (SpokeCluster CRD) → spoke-policy →
  cluster-registration → fleet.
tools:
  - run_in_terminal
---

# CAPO Secret + ArgoCD Bootstrap

**Prerequisite:** Agent 03 completed — `argocd-server` is Available.
**Critical ordering:** the CAPO secret MUST be created before the App-of-Apps
is applied. The `capo-identity` Application references it; if it is absent,
CAPO will install but the OpenStackClusterIdentity will never become ready.

## Container invocation pattern

```bash
cd /mnt/c/Users/boadeyem/Jetstream2-CSOC-POC/js-poc-csoc-bootstrap
KDIR="$(pwd)/.state/kubeconfigs"
```

## Step 1 — Create the CAPO and workload cloud secrets

This reads `credentials/runtime-clouds.yaml` (the restricted application
credential) and creates two secrets:
- `openstack-cloud-config` in `capo-system` — used by CAPO to talk to OpenStack
- `openstack-workload-cloud-config` in `spokeclusters` — injected into spoke clusters via ClusterResourceSet

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  bash scripts/bootstrap/credentials/create-runtime-cloud-secret.sh
```

Expected: script prints steps 1–5 and `[SUCCESS]`.

Verify both secrets exist:
```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  kubectl get secret openstack-cloud-config -n capo-system -o jsonpath="{.metadata.name}" && echo " OK" &&
  kubectl get secret openstack-workload-cloud-config -n spokeclusters -o jsonpath="{.metadata.name}" && echo " OK"
'
```

## Step 2 — Apply AppProjects and App-of-Apps

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  bash scripts/bootstrap/argocd/bootstrap-apps.sh
```

This script applies AppProjects, then the App-of-Apps, then waits for each
Application in dependency order with a 15-minute timeout per Application.
Expected final line: `[SUCCESS] App-of-Apps applied. GitOps owns platform controllers.`

This step takes 15–40 minutes for the full chain to converge.

## Step 3 — Monitor convergence (in a second terminal while step 2 runs)

Open a second WSL terminal and watch sync status:

```bash
cd /mnt/c/Users/boadeyem/Jetstream2-CSOC-POC/js-poc-csoc-bootstrap
KDIR="$(pwd)/.state/kubeconfigs"
watch -n 10 'KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl get applications -n argocd'
```

Expected wave progression:

| Wave | Applications | Healthy when |
|---|---|---|
| -20 | AppProjects applied imperatively | N/A |
| -10 | `kro` | kro-controller pod Running |
| -5 | `cert-manager`, `openstack-resource-controller`, `capi-operator` | CRDs Established |
| 0 | `capo-identity`, `csoc-platform-apis`, `spoke-policy`, `cluster-registration`, `csoc-fleet` | SpokeCluster CRD present |
| (root) | `csoc-app-of-apps` | all above Synced+Healthy |

## Step 4 — Verify controller CRDs after bootstrap

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  for crd in \
    certificates.cert-manager.io \
    clusters.cluster.x-k8s.io \
    openstackclusters.infrastructure.cluster.x-k8s.io \
    openstackclusteridentities.infrastructure.cluster.x-k8s.io \
    kubeadmcontrolplanes.controlplane.cluster.x-k8s.io \
    machinedeployments.cluster.x-k8s.io \
    helmchartproxies.addons.cluster.x-k8s.io \
    clusterresourcesets.addons.cluster.x-k8s.io \
    resourcegraphdefinitions.kro.run \
    spokeclusters.csoc.js2.org; do
      kubectl wait crd "$crd" --for=condition=Established --timeout=30s \
        && echo "OK: $crd" || echo "FAIL: $crd"
  done
'
```

Expected: all 10 print `OK:`.

## Step 5 — Verify capo-identity and fleet Applications

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  kubectl get application capo-identity -n argocd \
    -o jsonpath="{.status.sync.status} {.status.health.status}" && echo &&
  kubectl get application csoc-fleet -n argocd \
    -o jsonpath="{.status.sync.status} {.status.health.status}" && echo
'
```

Expected: `Synced Healthy` for both.

## Step 6 — Verify the SpokeCluster CR was created by fleet

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl get spokecluster -n spokeclusters
```

Expected: `poc-tenant-dev` exists. Phase will be `Pending` or early provisioning
stage — this is correct. CAPI provisioning happens in the next agent.

## Failure guidance

**`capo-identity` Degraded:** The `openstack-cloud-config` secret in `capo-system`
is absent or has wrong keys. Re-run step 1.

**`csoc-platform-apis` stuck Progressing:** KRO is not yet ready (wave -10
dependency). Check `kubectl get pods -n kro-system`. Wait for `kro-controller`
to be Running.

**`csoc-fleet` OutOfSync:** The fleet repo `main` branch must have the
`poc-tenant-dev` cluster.yaml. Verify remote: `kubectl get application csoc-fleet
-n argocd -o yaml | grep targetRevision`.

## Pass criteria

| Check | Expected |
|---|---|
| `create-runtime-cloud-secret.sh` | exits 0 |
| `openstack-cloud-config` in `capo-system` | exists |
| `openstack-workload-cloud-config` in `spokeclusters` | exists |
| `bootstrap-apps.sh` | exits 0 |
| all 10 CRDs | Established |
| `capo-identity` | Synced Healthy |
| `csoc-fleet` | Synced Healthy |
| `poc-tenant-dev` SpokeCluster | present in `spokeclusters` |

Proceed to **05-spoke-provision**.
