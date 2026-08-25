# controllers

Argo CD `Application` manifests for management-cluster controllers. All are members of the `rgds` AppProject. The `csoc-controllers` parent Application (declared in `argocd/apps/controllers.yaml`) watches this entire directory.

## Installed controllers

| File | Name | Version | Namespace | Sync wave |
|------|------|---------|-----------|-----------|
| `cert-manager.yaml` | cert-manager | v1.21.1 | `cert-manager` | −40 |
| `capi-operator.yaml` | capi-operator | 0.28.0 | `argocd` | −20 |
| `orc.yaml` | openstack-resource-controller | v2.6.0 | `orc-system` | −30 |
| `kro.yaml` | kro | 0.9.3 | `kro-system` | −10 |

The CAPI Operator installs CAPI core v1.12.11, kubeadm bootstrap/control-plane v1.12.11, and CAPO v0.14.7 as nested providers. KRO must be running before RGDs can be applied.

## Conventions

- Versions are pinned in [`versions.env`](../versions.env) and must be kept in sync with these manifests.
- `prune: false` on all Applications — controller removal is always a deliberate action.
- `ServerSideApply=true` on all Applications.
- Retry: 10 attempts, exponential backoff capped at 3 minutes.
