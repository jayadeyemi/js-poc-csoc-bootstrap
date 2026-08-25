---
description: >
  Verify the management cluster (js2-mgmt-cluster-2) is healthy and ready for
  ArgoCD installation. All commands run in WSL inside the management container.
tools:
  - run_in_terminal
---

# Management Cluster Health Check

**Gate:** All checks below must pass before proceeding to agent 02 or 03.

## Container invocation pattern

Every `kubectl` / `helm` command below runs inside the pinned management container:

```bash
cd /mnt/c/Users/boadeyem/Jetstream2-CSOC-POC/js-poc-csoc-bootstrap
PROFILE=dev KUBECONFIG_DIR="$(pwd)/.state/kubeconfigs" bash scripts/host/container/run.sh <cmd>
```

Alias this if convenient:
```bash
KDIR="$(pwd)/.state/kubeconfigs"
alias mc='PROFILE=dev KUBECONFIG_DIR="$KDIR" bash scripts/host/container/run.sh'
```

## Step 1 — Cluster reachability

```bash
mc kubectl cluster-info
```

Expected: API server URL `https://149.165.151.65:6443` and CoreDNS address shown.
Fail: any connection error → kubeconfig not at `.state/kubeconfigs/config`.

## Step 2 — Node readiness

```bash
mc kubectl get nodes -o wide
```

Expected: 2 nodes (1 control-plane, 1 worker), both `Ready`, no `SchedulingDisabled`.

Check taints — the provider-uninitialized taint must be absent:

```bash
mc kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints}{"\n"}{end}'
```

Expected: no `node.cloudprovider.kubernetes.io/uninitialized` taint on any node.
If present: OpenStack CCM is not running; investigate before continuing.

## Step 3 — System pod health

```bash
mc kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

Expected: zero rows (empty output = all pods healthy).

Spot-check the three critical system namespaces:

```bash
mc kubectl get pods -n kube-system
mc kubectl get pods -n calico-system
mc kubectl get pods -n openstack-system
```

Expected:
- `kube-system`: coredns (2/2 Running), kube-proxy, kube-apiserver, etcd, scheduler, controller-manager
- `calico-system`: calico-node (per node), calico-kube-controllers
- `openstack-system`: openstack-cloud-controller-manager

Fail: any pod in CrashLoopBackOff or Pending longer than 5 min → report full pod describe before continuing.

## Step 4 — Existing namespaces sanity

```bash
mc kubectl get namespaces
```

Expected namespaces present:
`calico-system`, `default`, `kube-node-lease`, `kube-public`, `kube-system`,
`network-operator`, `node-feature-discovery`, `node-problem-detector`,
`openstack-system`, `tigera-operator`.

For a first install, `argocd`, `capo-system`, `capi-system`, and `cert-manager`
must not exist. For the established dev CSOC, verify their workloads are
healthy instead of treating their presence as a failure.

## Step 5 — Cluster version

```bash
mc kubectl version --short 2>/dev/null || mc kubectl version
```

Expected server version: `v1.34.x`.

## Step 6 — Helm availability

```bash
mc helm version
mc helm repo list 2>/dev/null || true
```

Expected: Helm 3.21.4, no repos yet (clean state).

## Pass criteria

| Check | Expected |
|---|---|
| cluster-info | API server reachable |
| nodes | 2 Ready, no uninitialized taint |
| unhealthy pods | 0 |
| kube-system pods | all Running |
| calico-system pods | all Running |
| openstack-system (CCM) | Running |
| `argocd` namespace | absent |
| server k8s version | v1.34.x |
| helm version | 3.21.4 |

All pass → proceed to **02-manual-smoke-test** or **03-argocd-install** if you skip the smoke test.
