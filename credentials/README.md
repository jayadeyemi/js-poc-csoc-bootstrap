# Credentials directory

This directory holds ignored bootstrap and runtime credentials. Never commit a
live credential.

---

## Required credential separation

Application credentials are scoped, revocable, and do not expose your password.

Create two application credentials in the same project:

- `magnum-clouds.yaml`: short expiry and **Unrestricted (dangerous)** enabled;
  use only for Magnum create or reviewed delete operations.
- `runtime-clouds.yaml`: unrestricted disabled; use for CAPO, OpenStack CCM,
  Cinder CSI, and workload reconciliation.

The IDs must be different. Both must be scoped to project
`53f449a040d14cef8512b69e4ad521cd` and have an explicit future expiration.

Copy the examples, enter each ID/secret once, and protect both files:

Copy `clouds.yaml.example` to `clouds.yaml` in this directory and fill in your values:

```bash
cp credentials/magnum-clouds.yaml.example credentials/magnum-clouds.yaml
cp credentials/runtime-clouds.yaml.example credentials/runtime-clouds.yaml
chmod 600 credentials/magnum-clouds.yaml credentials/runtime-clouds.yaml
$EDITOR credentials/magnum-clouds.yaml
$EDITOR credentials/runtime-clouds.yaml
```

### 3. Supply to the management container

The container launcher mounts only those two files read-only under
`/run/csoc-credentials`. It shadows the workspace credential directory so the
same secrets are not also exposed through the writable workspace bind mount.

```
/run/csoc-credentials/magnum-clouds.yaml
/run/csoc-credentials/runtime-clouds.yaml
```

You can override the source path:

```bash
MAGNUM_CLOUDS_YAML=/secure/magnum.yaml \
RUNTIME_CLOUDS_YAML=/secure/runtime.yaml \
make container-run
```

---

## Supplying credentials for Cluster API Provider OpenStack (CAPO)

Once the management cluster is running, CAPO needs a Kubernetes secret.
Run the helper script — it is idempotent:

```bash
bash scripts/capi/create-cloud-secret.sh
```

This creates the secret `openstack-cloud-config` in namespace `capo-system`
from only `runtime-clouds.yaml`. The helper rejects an unrestricted runtime
credential.

---

## Security notes

- Never inject `magnum-clouds.yaml` into Kubernetes.
- Revoke the short-lived Magnum credential after the management cluster and
  acceptance checks succeed. Create a new temporary unrestricted credential
  for a future reviewed deletion.
- Rotate the restricted runtime credential independently and verify CAPO,
  LoadBalancer, and Cinder operations before revoking its predecessor.
- Do not print `OS_*` variables or application credential creation output.
