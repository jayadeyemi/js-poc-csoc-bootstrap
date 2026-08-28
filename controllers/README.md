# controllers

Argo CD `Application` manifests for management-cluster controllers. All are members of the `rgds` AppProject. The `csoc-controllers` parent Application (declared in `argocd/apps/controllers.yaml`) watches this entire directory.

## Installed controllers

| File | Name | Version | Namespace | Sync wave |
|------|------|---------|-----------|-----------|
| `cert-manager.yaml` | cert-manager | v1.21.1 | `cert-manager` | −40 |
| `capi-operator.yaml` | capi-operator | 0.28.0 | `argocd` | −20 |
| `orc.yaml` | openstack-resource-controller | v2.6.0 | `orc-system` | −30 |
| `kro.yaml` | kro | 0.9.3 | `kro-system` | −10 |
| `registration.yaml` | spoke registration controller + v2 admission policy | pinned runtime | `cluster-registration` | −19…−17 |

The CAPI Operator installs CAPI core v1.12.11, kubeadm bootstrap/control-plane v1.12.11, and CAPO v0.14.7 as nested providers. KRO must be running before RGDs can be applied.

`registration.yaml` is a raw multi-document controller package rather than a
nested Argo `Application`. It registers as soon as the control-plane API is
reachable, so registration never waits on the foundation it enables. The CAPI
admin kubeconfig stays in memory while the broker installs bootstrap RBAC and
the two credential-only Secrets required in the spoke: `cloud-config` and a
namespace-scoped management kubeconfig for Cluster Autoscaler.

Central Argo receives three separate renewable 90-day identities: a
namespace-bound application cluster name, an explicit `<cluster>-platform`
identity, and an explicit `<cluster>-monitoring` identity. The autoscaler gets
a fourth certificate bound only to CAPI objects in the account namespace.
Certificates renew with 30 days left or when `rotationRequest` changes; their
revisions trigger workload rollouts. Finalization remains blocked while typed
applications reference the cluster or retirement approval is absent, and an
unreachable spoke retains its finalizer.

## Conventions

- Versions are pinned in [`versions.env`](../versions.env) and must be kept in sync with these manifests.
- `prune: false` on all Applications — controller removal is always a deliberate action.
- `ServerSideApply=true` on all Applications.
- Retry: 10 attempts, exponential backoff capped at 3 minutes.
