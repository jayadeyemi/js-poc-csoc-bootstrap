# CSOC infrastructure-change workflow

The files in `iac/csoc/profiles/` are the declarative source of truth for each
Magnum management cluster. Fleet `SpokeCluster` instances are the declarative
source of truth for CAPI/CAPO spokes. A change is either an in-place worker
bounds update or an explicitly reviewed replacement; there is no generic
"update every field" operation.

## Supported changes

| Cluster | Change | Support | Workflow |
|---|---|---|---|
| Magnum CSOC | Rename | Replacement only | Declare a new profile/name with new state and kubeconfig paths; provision and migrate after review. |
| Magnum CSOC | Worker bounds | In place | Change `MAGNUM_MIN_NODE_COUNT`/`MAGNUM_MAX_NODE_COUNT`, plan, then run the confirmed resize target. |
| Magnum CSOC | Current worker count | Autoscaler-owned | Change bounds or workload demand; do not create a second scaler or maintain count as IaC drift. |
| Magnum CSOC | Control-plane count/flavor, worker flavor, template/image, network, keypair, root volume | Replacement only | Create a separately named profile and migrate. |
| CAPI spoke | Rename | Replacement only | Add the new fleet instance, accept it, migrate workloads, then use the reviewed retirement workflow for the old instance. |
| CAPI spoke | `minNodes`/`maxNodes` | In place | Change only `SpokeCluster.spec.kubernetes` in the fleet repository and let Argo/KRO reconcile. |
| CAPI spoke | Project, image, flavors, control-plane count, network, CIDRs, keypair policy | Replacement only | These values flow through immutable configuration; retire and recreate the consuming spoke. |

Magnum's update API does not rename a cluster or change its master count. A
Kubernetes/CAPI name also anchors generated resource names, labels, owner
references, Secrets, and load balancers, so a spoke rename is likewise a new
cluster rather than a cosmetic update.

## Management-cluster plan and resize

Edit the selected tracked profile, then run the read-only plan inside its
profile container:

```bash
make validate-clusters
make csoc-plan PROFILE=staging
```

The plan labels each difference as `no-op`, `in-place`, `observe-only`, or
`replace-cluster`. Only worker minimum/maximum changes can proceed through the
in-place target:

```bash
make csoc-resize PROFILE=staging CONFIRM=js-csoc-staging
make clusters-verify PROFILE=staging
```

`csoc-resize` validates every declared cluster, runs read-only OpenStack and
ownership preflight, requires the exact cluster-name confirmation, and patches
only the owned UUID's `default-worker` bounds. It never renames a cluster,
changes an immutable field, or submits a create/delete request.

## Spoke change workflow

For an active tuple, edit only these normal mutable fields in
`environments/<owner>/accounts/<account>/<app>/<environment>/cluster.yaml`:

```yaml
spec:
  kubernetes:
    minNodes: 1
    maxNodes: 3
```

Run `make validate` in the bootstrap repository, review and merge the fleet
change, wait for Argo/KRO reconciliation, then run `make clusters-verify` in
the selected CSOC container. All other spoke allocation fields are write-once
and use the replacement/retirement procedure in `OPERATIONS.md`.

## All profiles and containers

One pinned image is shared, while every profile has an isolated operator
container and kubeconfig directory:

```bash
make container-build
make containers-up
make containers-status
make clusters-verify-all
make containers-stop
```

Starting an operator container does not provision its profile. The all-profile
live gate skips profiles without ownership state and fails if none are
provisioned. Within each provisioned management cluster it verifies the Magnum
CSOC first, then every active SpokeCluster, its KRO readiness/addons/autoscaler
status, CAPI readiness, and MachineDeployment readiness and bounds.

`make validate` always includes `make validate-clusters`. The inventory-wide
static gate discovers profiles and fleet YAML rather than relying on a
hard-coded cluster list, so a newly added profile or spoke is validated
automatically.

During the `csoc-*` to `js-csoc-*` replacement, static validation recognizes
only a retained legacy ownership record with the same profile and template and
emits a migration warning. Live preflight still fails closed while that legacy
state file exists; it cannot create the new exact-name cluster until the old
Magnum UUID is absent and the exact-UUID retirement workflow clears ownership.
