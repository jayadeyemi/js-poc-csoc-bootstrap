# Credentials directory

This directory holds ignored bootstrap and runtime credentials. Never commit a
live credential.

---

## Required credential separation

Application credentials are scoped, revocable, and do not expose your password.

Create one CSOC bootstrap credential and one restricted spoke-provisioning
credential per `SpokeIdentity`:

- `magnum-clouds.yaml`: short expiry and **Unrestricted (dangerous)** enabled;
  use only for Magnum create or reviewed delete operations.
- `accounts/<identity>/clouds.yaml`: unrestricted disabled; use only for CAPO, ORC,
  OpenStack CCM, Cinder CSI, and workload reconciliation in that account only.

The Magnum and spoke credential IDs must be different, even when both are
scoped to the same OpenStack project. Every spoke credential must be
scoped to the project declared by its trusted fleet `SpokeIdentity`
instance and have an explicit future expiration.

Copy the examples, enter each ID/secret once, and protect both files:

For the initial account:

```bash
cp scripts/host/credentials/magnum-clouds.yaml.example scripts/host/credentials/magnum-clouds.yaml
cp scripts/host/credentials/accounts/test-poc/clouds.yaml.example scripts/host/credentials/accounts/test-poc/clouds.yaml
chmod 600 scripts/host/credentials/magnum-clouds.yaml scripts/host/credentials/accounts/test-poc/clouds.yaml
$EDITOR scripts/host/credentials/magnum-clouds.yaml
$EDITOR scripts/host/credentials/accounts/test-poc/clouds.yaml
```

When a private seed cloud is authorized to create application credentials, use
the host workflow so credential secrets are written directly to a mode-0600
file and never printed:

```bash
make credential-create \
  SOURCE=/secure/seed-clouds.yaml \
  OUTPUT=scripts/host/credentials/magnum-clouds.yaml \
  NAME=js-csoc-dev-magnum-YYYYMMDD \
  POLICY=unrestricted \
  EXPIRES_AT=YYYY-MM-DDTHH:MM:SSZ
```

Use a unique name and output file for every CSOC environment. Use
`POLICY=restricted` for account runtime credentials.

### 3. Supply to the management container

The container launcher mounts the Magnum file and account directory read-only under
`/run/csoc-credentials`. It shadows the workspace credential directory so the
same secrets are not also exposed through the writable workspace bind mount.

```
/run/csoc-credentials/magnum-clouds.yaml
/run/csoc-credentials/accounts/<identity>/clouds.yaml
```

You can override the source path:

```bash
MAGNUM_CLOUDS_YAML=/secure/magnum.yaml \
RUNTIME_CREDENTIALS_DIR=/secure/accounts \
make container-run
```

---

## Supplying credentials for Cluster API Provider OpenStack (CAPO)

Once the management cluster is running, CAPO needs a Kubernetes secret.
Run the helper script — it is idempotent:

```bash
bash scripts/bootstrap/credentials/create-runtime-cloud-secret.sh test-poc
# or reconcile every configured account
bash scripts/bootstrap/credentials/create-runtime-cloud-secret.sh --all
```

This creates `<identity>-cloud-config` and
`<identity>-workload-cloud-config` only in `spokeclusters-<identity>`. The
helper rejects unrestricted credentials and project mismatches.

---

## Security notes

- Never inject `magnum-clouds.yaml` into Kubernetes or use it for a spoke.
- Revoke the short-lived Magnum credential after the management cluster and
  acceptance checks succeed. Create a new temporary unrestricted credential
  for a future reviewed deletion.
- Rotate the restricted runtime credential independently and verify CAPO,
  LoadBalancer, and Cinder operations before revoking its predecessor.
- Do not print `OS_*` variables or application credential creation output.
