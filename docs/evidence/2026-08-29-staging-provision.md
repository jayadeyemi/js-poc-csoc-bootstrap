# `js-csoc-staging` provisioning evidence — 2026-08-29

## Candidate and credential

- Bootstrap candidate before the live request: `695943a` (`Use m3.quad for dev management`).
- Magnum application credential name: `CSOC-dev`.
- Application credential ID: `77aa8edf0c8d4a2cb0c195fd3b745252`.
- The credential authenticated in project `53f449a040d14cef8512b69e4ad521cd`,
  was unrestricted, and intentionally had no expiration.
- The complete local validation gate passed before the request.
- Live preflight passed the separated-credential, exact-name absence, template,
  image, network, flavor, keypair, quota, and load-balancer service checks.

## Declared immutable topology

- Exact name: `js-csoc-staging`.
- Control plane: 3 `m3.small` nodes.
- Workers: 2 `m3.quad` nodes with fixed bounds `2..2`.
- Boot volumes: 20 GiB per node.
- Provider template: `284de191-b8ea-4dae-9046-6ab982bd1c3a`.
- Image: `18895dd1-6e94-482b-9a62-9573328c7429`.
- Fixed network/subnet: `b1bca63f-e34b-47e5-bf96-565515f38326` /
  `d676529f-7335-417d-a1e3-283f2411af3b`.

## Live result

- Magnum UUID: `bcbcd17e-15c0-42ed-8c0a-544985b06ebb`.
- Heat stack: `js-csoc-staging-d6mu2q273fdj`.
- API load balancer: `2710f16b-64e9-41b8-87f1-3d1c241aaa01`.
- Ownership state: `.state/csoc/staging/magnum-cluster.json`.
- Ownership-state SHA-256:
  `eeba73209230c42ea222729cbf5d3e3d57f5a901f79acbb4ecdd54fc1e1c2727`.
- Redacted diagnostic bundle:
  `.state/diagnostics/20260829T045921Z/`.

One create request was accepted at `2026-08-29T04:38:47Z`. The health-aware
waiter ran for its full 2,700-second deadline and stopped at `05:24:16Z` without
submitting another request. Magnum remained `CREATE_IN_PROGRESS` / `UNHEALTHY`
with no status reason and no update after `04:38:57Z`. The API load balancer
remained `PENDING_CREATE` / `OFFLINE`; no servers were created, and both node
groups remained `CREATE_IN_PROGRESS`.

Do not retry create. Preserve the ownership file and redacted bundle while
Jetstream2 investigates the Octavia/Magnum backend. No Argo bootstrap, fleet
reconciliation, spoke creation, or production provisioning was attempted.
