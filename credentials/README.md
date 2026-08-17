# Credentials directory

This directory holds **runtime** credentials. **Nothing here should be committed to git** (see `.gitignore`).

---

## Recommended: OpenStack Application Credentials

Application credentials are scoped, revocable, and do not expose your password.

### 1. Create credentials on Jetstream2 Horizon or CLI

```bash
# Via CLI (run once on a machine with openstack client)
openstack application credential create jetstream2-mgmt \
  --description "Jetstream2 CSOC management credential" \
  --unrestricted       # remove if minimal-privilege rules apply
```

Capture the `id` and `secret` from the output.

### 2. Populate clouds.yaml

Copy `clouds.yaml.example` to `clouds.yaml` in this directory and fill in your values:

```bash
cp credentials/clouds.yaml.example credentials/clouds.yaml
$EDITOR credentials/clouds.yaml
```

### 3. Supply to the management container

The run script mounts `credentials/clouds.yaml` read-only into the container:

```
/home/jetstream/.config/openstack/clouds.yaml   (inside container)
```

You can override the source path:

```bash
CREDENTIALS_DIR=/path/to/your/openstack/dir make container-run
```

---

## Supplying credentials for Cluster API Provider OpenStack (CAPO)

Once the management cluster is running, CAPO needs a Kubernetes secret.
Run the helper script — it is idempotent:

```bash
bash scripts/capi/create-cloud-secret.sh
```

This creates the secret `openstack-cloud-config` in namespace `capo-system`
from the same `clouds.yaml` used above.

---

## Security notes

- Use application credentials, not your user password.
- Rotate credentials after any exposure.
- Do not set `--unrestricted` in production; create a role assignment instead.
- The `credentials/clouds.yaml` file is excluded from git by `.gitignore`.
