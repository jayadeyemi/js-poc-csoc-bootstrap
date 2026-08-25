# argocd

Argo CD configuration for the CSOC management cluster. Applied once by `scripts/bootstrap/argocd/bootstrap-apps.sh`; Argo CD self-manages everything here after that.

## Structure

```
app-of-apps.yaml        root Application — watches the whole argocd/ tree
apps/
  controllers.yaml      csoc-controllers Application (sync-wave -50)
  rgds.yaml             rgds Application (sync-wave -5)
  fleet.yaml            csoc-fleet Application (sync-wave 5)
projects/
  rgds.yaml             AppProject for controllers and RGD definitions
  csoc-fleet.yaml       AppProject for account-scoped fleet instances
  csoc-baseline.yaml    AppProject boundary for trusted workload instances
```

## Sync wave order

| Wave | Resource |
|------|---------|
| −50 | `csoc-controllers` — installs cert-manager, CAPI Operator, KRO, ORC |
| −40 | cert-manager (declared in `controllers/`) |
| −30 | ORC |
| −20 | CAPI Operator (and AppProjects) |
| −10 | KRO |
| −5  | `rgds` — KRO compiles RGDs into CRDs |
| 5   | `csoc-fleet` — fleet instances reference the CRDs |

## Projects

| Project | Source repos | Purpose |
|---------|-------------|---------|
| `rgds` | bootstrap, app-catalog, chart registries | Controllers and RGD definitions |
| `csoc-fleet` | fleet | Account-scoped graph instances |
| `csoc-baseline` | app-catalog, fleet | Trusted CSOC-local and spoke workload graph instances |

There is deliberately no `csoc-baseline` Application or ApplicationSet. The
project is the authorization boundary for trusted workload instances; the
single fleet Application currently owns the CSOC and opt-in spoke `HelloApp`
instances.

`prune: false` is set on all Applications. Removing a spoke from Git therefore
makes it an orphan warning without deleting it. After the fleet default branch
and `csoc-fleet` sync status prove retirement intent, use the ownership-gated
script documented in `OPERATIONS.md`; it deletes workload, CAPI, and network
owners in that order.
