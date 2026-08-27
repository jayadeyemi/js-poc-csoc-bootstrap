---
applyTo: "iac/**,scripts/operations/**,OPERATIONS.md"
---

# Migration workflow

Inventory and back up before planning a migration. Treat cluster name,
control-plane topology, and volume shrink as replacement-required. Produce an
exact-source/exact-target plan, supported transfer method, acceptance checks,
rollback window, and separately authorized exact-UUID retirement. Never adopt
same-name resources or infer ownership from names.
