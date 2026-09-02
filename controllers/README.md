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

## Scale controls

The manifests expose the effective defaults so a benchmark can identify the
limiting queue before any value is raised.

| Controller | Exposed defaults | What the knobs control |
|---|---|---|
| Argo CD | status `20`, operations `10`, kubectl `20`, API `50/100`, repo generation `1` | Application observation, concurrent syncs, child kubectl processes, API throttling, and manifest generation |
| KRO | RGD `1`, GraphRevision `1`, dynamic instances `1`, API `100/150`, rate/burst `10/100` | Definition compilation and instance graph work; dynamic concurrency is the first scale-test tuning point |
| CAPI core | object reconcilers `10`, cluster cache `100`, API `20/30` | CAPI object workers, workload-cluster cache startup, and management API throttle |
| kubeadm providers | config/control-plane `10`, cache `100`, API `20/30` | Bootstrap data and control-plane reconciliation |
| CAPO | cluster/machine/template `10`, credential cache `10`, API `20/30` | Parallel OpenStack cluster and Nova work plus cached credential scopes |
| CAAPH | chart/release `10`, API `20/30` | Concurrent addon reconciliation |
| ORC | replica `1`, credential cache `10` | Cached OpenStack scopes only; v2.6.0 has no reconcile-concurrency or Kubernetes-client-QPS flag |

CAPI provider releases and Argo CD have no resource request/limit defaults;
their explicit `resources: {}` entries document that fact. KRO and ORC retain
their pinned upstream requests and limits. Raise KRO dynamic concurrency first
after the default run. With eleven identities, raise ORC's cache to at least
`16` to avoid eviction, but do not describe this as additional reconcile
workers. Any concurrency increase must be paired with adequate CPU/memory and,
where supported, QPS/burst. If controller logs show client throttling, increase
QPS and burst together; if OpenStack reports HTTP 429, timeout, or capacity
errors, reduce concurrency instead.
