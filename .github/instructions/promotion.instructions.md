---
applyTo: ".github/**,iac/csoc/profiles/**,argocd/**"
---

# Promotion workflow

Coordinate catalog, fleet, then bootstrap. Promote selected reviewed commits
from `environment/dev` to `environment/staging` to `environment/prod`. Validate
that all three repos use one environment revision and that fleet tuple ownership
is unique. Never blanket-merge environment branches or enable live sync merely
because static checks pass.
