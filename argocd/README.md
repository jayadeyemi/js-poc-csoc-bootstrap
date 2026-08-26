# argocd

Argo CD configuration for both CSOC profiles. Development selects
`argocd/apps/` from default branches. Production selects `argocd/prod/apps/`
from `release/prod` and intentionally has no fleet Application.

## Structure

```
app-of-apps.yaml        development root — selects projects and dev apps
apps/
  controllers.yaml      csoc-controllers Application (sync-wave -50)
  rgds.yaml             rgds Application (sync-wave -5)
  fleet.yaml            csoc-fleet Application (sync-wave 5)
prod/apps/
  controllers.yaml      release/prod controller source
  rgds.yaml             release/prod catalog source; no fleet Application
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
| `csoc-baseline` | app-catalog, fleet | Trusted CSOC-local workload graph instances only |

There is deliberately no `csoc-baseline` Application or ApplicationSet. The
project is the authorization boundary for trusted workload instances; the
single fleet Application owns the CSOC-local `HelloApp` plus any opt-in
`SpokeHelloApp` or `SpokeGitOps` instances. `SpokeHelloApp` delivers resources
from the CSOC through CAPI; `SpokeGitOps` installs a separate Argo CD in the
spoke and points its root Application at a public repository. A workload must
choose exactly one ownership path.

`prune: false` is set on all Applications. Removing a spoke from Git therefore
makes it an orphan warning without deleting it. After the fleet default branch
and `csoc-fleet` sync status prove retirement intent, use the ownership-gated
script documented in `OPERATIONS.md`; it deletes workload, CAPI, and network
owners in that order.
