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

## Controller recovery

Argo CD owns cert-manager, CAPI, CAPO, ORC, CAAPH, KRO, the SpokeCluster policy, and cluster
registration. There is no `clusterctl` installation path. Diagnose drift with:

```bash
kubectl get applications -n argocd
kubectl get providers -A
kubectl get resourcegraphdefinitions,graphrevisions
kubectl get clusters,openstackclusters,kubeadmcontrolplanes,machinedeployments -A
```

Repair the Git declaration and let Argo reconcile it. Do not manually replace
provider CRDs or generated CAPI objects.

## Rotate OpenStack application credentials

1. Create a new restricted application credential in Jetstream2.
2. Replace the ignored `credentials/runtime-clouds.yaml` atomically and keep mode
   `0600`.
3. Run `make preflight` with the new credential.
4. Run `make capi-secret`. This updates the CAPO secret and the reconciled
   workload `cloud-config` resource-set payload without printing either secret.
5. Restart CAPO, OpenStack CCM, and Cinder CSI only if their controllers do not
   observe the secret update; verify logs before forcing a restart.
6. Confirm an OpenStack API read, a `LoadBalancer` reconciliation, and a
   Cinder-backed PVC operation, then revoke the old application credential.

## Rotate Argo spoke credentials

CAPI refreshes each `<cluster>-kubeconfig` secret. The registration CronJob
reconciles the corresponding Argo cluster secret every two minutes, including
labels and client credentials. Verify its latest Job before revoking old
credentials:

```bash
kubectl get jobs -n cluster-registration --sort-by=.metadata.creationTimestamp
kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=cluster
```

## Cleanup gate

Deleting a fleet `SpokeCluster`, a CAPI `Cluster`, or the Magnum management
cluster can delete cloud infrastructure and data. Cleanup is never automatic:
record the exact resource UUIDs, backups, tenant approval, and an OpenStack
inventory diff in a reviewed change before issuing any delete operation.

For a reviewed Magnum deletion, run
`scripts/magnum/delete-owned.sh <reviewed-uuid>`. The argument must match
`.state/magnum-cluster.json`; the script captures diagnostics, sends exactly
one delete request, waits up to 30 minutes, stops on `DELETE_FAILED`, and removes
ownership state only after the record disappears. If the first watcher times
out while the record is still `DELETE_IN_PROGRESS`, running the same exact-UUID
command resumes polling without sending another delete request. It also clears
state safely if the reviewed record disappeared after the previous watcher
stopped. Never resend a stalled delete manually or remove Kubernetes finalizers.
