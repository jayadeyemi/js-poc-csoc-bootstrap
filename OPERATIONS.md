# Operations and recovery

All commands run from `js-poc-csoc-bootstrap` inside the pinned management
container. `make bootstrap` builds the image on the host and invokes the inner
pipeline non-interactively. Live cluster creation is allowed only after local
`make validate`, `make security-scan`, and `make preflight` pass; GitHub Actions
is not a deployment gate.

## Resume or repeat bootstrap

`make bootstrap` is restartable. Magnum lifecycle commands resolve only the
UUID in `.state/magnum-cluster.json`; a same-named cluster without matching
state is rejected. If a run is interrupted, inspect that state and the UUID
with `openstack coe cluster show <uuid>` before repeating the command.

Do not reconstruct ownership state from a cluster name alone. If the state
file is lost, stop and review the cluster UUID, project, creation time, Heat
stack, and Git history before authorizing an explicit recovery operation.

Kubeconfig merges make a timestamped `0600` backup beside the destination.
Restore the most recent backup only after checking its contexts with
`kubectl --kubeconfig <backup> config get-contexts`.

## Magnum health and support evidence

Creation succeeds only when Magnum is complete and reports `HEALTHY`. After 20
minutes without workers, `magnum-wait` writes a redacted bundle under
`.state/diagnostics/` and continues the original request. It never submits a
duplicate create.

Use `make magnum-diagnose` for the cluster record, node groups, servers, and
load balancers. If the API is reachable but the control plane is NotReady and
Calico/CCM objects are absent, preserve provider ownership: do not install a
second CNI, remove finalizers, or edit provider-side CAPI objects. Give
Jetstream2 support the owned UUID, stack ID, API address, health, update time,
and diagnostic bundle.

## Kubernetes API reachability gates

The exact CSOC/provider-cluster kubeconfig must pass authenticated HTTPS
reachability before Argo CD is installed or any spoke is processed. The
management verification runs the shared checker with an exact initial
Ready-node count:

```bash
scripts/lib/kubernetes-reachability.sh \
  --name "$MAGNUM_CLUSTER_NAME" \
  --kubeconfig "${MAGNUM_KUBECONFIG_DIR:-$HOME/.kube}/${MAGNUM_CLUSTER_NAME}.yaml" \
  --minimum-ready 2 \
  --expected-endpoint "https://<api-address>:6443"
```

The checker validates the kubeconfig, HTTPS endpoint, `/readyz`, authorization
to list nodes, Ready-node count, and absence of the OpenStack
cloud-provider-uninitialized taint. It never prints certificate or key data.

Spoke workloads are reconciled by KRO-created CAPI addon resources. No Argo
cluster registration or ApplicationSet path is used.

The CSOC and spoke Hello workloads each use a dedicated OpenStack application
load balancer annotated as internal-only. Their VIPs are reachable only over
the corresponding private cloud network; they do not receive public floating
IPs. The existing Magnum/CAPO load balancers remain dedicated to Kubernetes
API port 6443. Public application access requires a separate reviewed change
with an explicit trusted source CIDR and proof that Octavia enforces source
ranges; `0.0.0.0/0` is not acceptable.

## Controller recovery

Argo CD owns cert-manager, CAPI, CAPO, ORC, CAAPH, KRO, RGD definitions, and
fleet graph instances. There is no `clusterctl` installation path. Diagnose drift with:

```bash
kubectl get applications -n argocd
kubectl get providers -A
kubectl get resourcegraphdefinitions,graphrevisions
kubectl get clusters,openstackclusters,kubeadmcontrolplanes,machinedeployments -A
```

Repair the Git declaration and let Argo reconcile it. Do not manually replace
provider CRDs or generated CAPI objects.

## Rotate spoke OpenStack credentials

1. Create a new restricted application credential in Jetstream2.
2. Atomically replace
   `scripts/host/credentials/accounts/<identity>/clouds.yaml` and retain mode
   `0600`.
3. Run `scripts/bootstrap/credentials/create-runtime-cloud-secret.sh <identity>`.
   The helper verifies the trusted project and updates only that identity's
   account-scoped CAPO/ORC and workload secrets without printing their values.
4. Confirm a CAPO read, internal load-balancer reconciliation, and Cinder PVC
   operation, then revoke the old credential.

Magnum credentials are rotated independently and must never be loaded into a
spoke account namespace.

## Cleanup gate

Deleting a fleet `SpokeCluster`, a CAPI `Cluster`, or the Magnum management
cluster can delete cloud infrastructure and data. Cleanup is never automatic:
record the exact resource UUIDs, backups, tenant approval, and an OpenStack
inventory diff in a reviewed change before issuing any delete operation.

For a reviewed Magnum deletion, run
`scripts/operations/magnum/delete-owned.sh <reviewed-uuid>`. The argument must match
`.state/magnum-cluster.json`; the script captures diagnostics, sends exactly
one delete request, waits up to 30 minutes, stops on `DELETE_FAILED`, and removes
ownership state only after the record disappears. If the first watcher times
out while the record is still `DELETE_IN_PROGRESS`, running the same exact-UUID
command resumes polling without sending another delete request. It also clears
state safely if the reviewed record disappeared after the previous watcher
stopped. Never resend a stalled delete manually or remove Kubernetes finalizers.
