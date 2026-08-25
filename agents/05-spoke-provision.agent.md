---
description: >
  Watch poc-tenant-dev SpokeCluster provision through CAPI/CAPO on Jetstream2
  OpenStack. Monitors control plane, worker MachineDeployment, and all addons
  (Calico, OpenStack CCM, Cinder CSI, Cluster Autoscaler). Extracts and saves
  the spoke kubeconfig when the cluster is Ready.
tools:
  - run_in_terminal
---

# Spoke Cluster Provisioning

**Prerequisite:** Agent 04 completed — the `accounts/test-poc` graph instances
exist and all controller CRDs are Established.
**Duration:** 15–30 minutes for full provisioning.

## Container invocation pattern

```bash
cd /mnt/c/Users/boadeyem/Jetstream2-CSOC-POC/js-poc-csoc-bootstrap
KDIR="$(pwd)/.state/kubeconfigs"
```

## Step 1 — Confirm the SpokeCluster spec

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl get spokecluster poc-tenant-dev -n spokeclusters-test-poc -o yaml
```

Confirm:
- `spec.kubernetes.minNodes: 2`, `maxNodes: 4`
- `test-poc-kubernetes-config` contains one approved `generalWorkerFlavor`
- no immutable ConfigMap or environment instance contains `minWorkers`,
  `maxWorkers`, GPU, high-memory, or `nodeClass` fields

The worker bounds are deliberately mutable on `SpokeCluster`. Kubernetes
version, control-plane settings, image, keypair, and the single general worker
flavor come from graph-produced immutable account ConfigMaps.

## Step 2 — Watch CAPI object creation (poll every 30 s)

Open a second terminal to watch object state while this agent monitors in the first:

```bash
cd /mnt/c/Users/boadeyem/Jetstream2-CSOC-POC/js-poc-csoc-bootstrap
KDIR="$(pwd)/.state/kubeconfigs"
watch -n 30 'KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c "
  echo === CAPI objects === &&
  kubectl get cluster,openstackcluster,kubeadmcontrolplane,machinedeployment \
    -n spokeclusters-test-poc 2>/dev/null &&
  echo &&
  echo === SpokeCluster status === &&
  kubectl get spokecluster poc-tenant-dev -n spokeclusters-test-poc \
    -o custom-columns=NAME:.metadata.name,READY:.status.ready,PHASE:.status.phase,ENDPOINT:.status.endpoint 2>/dev/null
"'
```

## Step 3 — Monitor KubeadmControlPlane readiness

The control-plane machine (1 replica, `m3.small`) provisions first.

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  kubectl wait kubeadmcontrolplane poc-tenant-dev-control-plane \
    -n spokeclusters-test-poc \
    --for=jsonpath="{.status.ready}"=true \
    --timeout=20m
'
```

Expected: exits 0 when the control plane is Ready.

While waiting, check the OpenStackCluster for the API load-balancer IP:

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl get openstackcluster poc-tenant-dev -n spokeclusters-test-poc \
    -o jsonpath='{.status.apiServerLoadBalancer.ip}{"\n"}'
```

## Step 4 — Monitor worker MachineDeployment

Workers (`minNodes: 2`, approved general flavor `m3.medium`) are created after
the control plane is Ready. Scaling may change the replica count within the
mutable `2..4` bounds; it does not change the worker flavor.

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  kubectl rollout status machinedeployment/poc-tenant-dev-workers \
    -n spokeclusters-test-poc --timeout=20m
'
```

Or poll manually:
```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl get machinedeployment poc-tenant-dev-workers -n spokeclusters-test-poc \
    -o jsonpath='{.status.readyReplicas}/{.status.replicas}{"\n"}'
```

Expected: `2/2`.

## Step 5 — Verify addons via HelmChartProxy

KRO creates HelmChartProxy resources for Calico, OpenStack CCM, and Cinder CSI.
These install onto the spoke once it is provisioned.

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl get helmchartproxy -n spokeclusters-test-poc
```

Expected: three proxies (`poc-tenant-dev-calico`, `poc-tenant-dev-openstack-ccm`,
`poc-tenant-dev-cinder-csi`), all with `READY=true` in their status.

Check addon conditions:
```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  for proxy in poc-tenant-dev-calico poc-tenant-dev-openstack-ccm poc-tenant-dev-cinder-csi; do
    kubectl get helmchartproxy "$proxy" -n spokeclusters-test-poc \
      -o jsonpath="{.metadata.name}: ready={.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}" 2>/dev/null \
      || echo "$proxy: not yet created"
  done
'
```

Expected: all three show `ready=True`.

## Step 6 — Wait for SpokeCluster Ready

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  until kubectl get spokecluster poc-tenant-dev -n spokeclusters-test-poc \
      -o jsonpath="{.status.ready}" 2>/dev/null | grep -q "^true$"; do
    phase=$(kubectl get spokecluster poc-tenant-dev -n spokeclusters-test-poc \
      -o jsonpath="{.status.phase}" 2>/dev/null || echo unknown)
    echo "$(date -u +%H:%M:%SZ) phase=$phase — waiting..."
    sleep 30
  done
  echo "SpokeCluster poc-tenant-dev is Ready"
'
```

`status.ready` is `true` when: CAPI Cluster Ready AND Calico Ready AND CCM Ready AND CSI Ready AND autoscaler available ≥ 1.

## Step 7 — Extract and save the spoke kubeconfig

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh bash -c '
  kubectl get secret poc-tenant-dev-kubeconfig \
    -n spokeclusters-test-poc \
    -o jsonpath="{.data.value}" | base64 -d \
    > /workspace/js-poc-csoc-bootstrap/.state/kubeconfigs/poc-tenant-dev.yaml
  chmod 600 /workspace/js-poc-csoc-bootstrap/.state/kubeconfigs/poc-tenant-dev.yaml
  echo "Saved to .state/kubeconfigs/poc-tenant-dev.yaml"
'
```

## Step 8 — Verify spoke namespaces

```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl --kubeconfig /home/jetstream/.kube/poc-tenant-dev.yaml get namespaces
```

Or outside the container (path differs):
```bash
kubectl --kubeconfig \
  /mnt/c/Users/boadeyem/Jetstream2-CSOC-POC/js-poc-csoc-bootstrap/.state/kubeconfigs/poc-tenant-dev.yaml \
  get namespaces
```

Expected spoke namespaces: `default`, `kube-system`, `kube-public`, `kube-node-lease`,
`calico-system` (or `tigera-operator`), `openstack-system`.

## Failure guidance

**OpenStackCluster stuck creating:** Check CAPO pod logs:
```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl logs -n capo-system -l cluster.x-k8s.io/provider=infrastructure-openstack --tail=50
```

Common causes: CAPO secret has wrong credentials, OpenStack quota exceeded,
external network ID mismatch in `cluster.env`.

**KubeadmControlPlane machines not becoming Ready:** Check machine status:
```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl get machines -n spokeclusters-test-poc -o wide
```

**HelmChartProxy never installs addons:** Verify `clusterresourceset`
`poc-tenant-dev-openstack-cloud-config` shows `ResourcesApplied`:
```bash
KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh \
  kubectl get clusterresourceset poc-tenant-dev-openstack-cloud-config \
    -n spokeclusters-test-poc -o jsonpath='{.status.conditions}'
```

## Pass criteria

| Check | Expected |
|---|---|
| KubeadmControlPlane ready | true |
| MachineDeployment ready replicas | 2/2 |
| calico HelmChartProxy | Ready=True |
| openstack-ccm HelmChartProxy | Ready=True |
| cinder-csi HelmChartProxy | Ready=True |
| SpokeCluster.status.ready | true |
| spoke kubeconfig | saved to `.state/kubeconfigs/poc-tenant-dev.yaml` |
| spoke namespaces | reachable, kube-system Running |

After readiness, verify the `HelloApp/poc-tenant-dev` ClusterResourceSet,
that its internal-only application `LoadBalancer` returns
`Hello poc-tenant-dev.`, Cinder PVC read/write, and bounded `2→3→2`
autoscaling. Verify `CSOCHelloApp/csoc` separately returns `Hello CSOC.` from
its own internal application load balancer. Neither application may reuse the
Kubernetes API load balancer or receive a public floating IP. Registration and
Argo ApplicationSets are intentionally not part of this architecture.
