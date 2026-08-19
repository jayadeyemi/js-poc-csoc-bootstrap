# Operations and recovery

All commands run from `js-poc-csoc-bootstrap` inside the pinned management
container. Live cluster creation is allowed only after `make validate`,
`make security-scan`, and `make preflight` pass.

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
2. Replace the ignored `credentials/clouds.yaml` atomically and keep mode
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
