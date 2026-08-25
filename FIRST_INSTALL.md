# First installation

This checklist configures a new CSOC and optional spoke accounts. Magnum creates
the CSOC Kubernetes management cluster in an existing OpenStack cloud. KRO,
ORC, CAPI, and CAPO later create spoke resources in that cloud; none of these
steps installs OpenStack.

Do not enable Argo ownership until the local gate passes and the AppProjects,
controller Applications, RGD definitions, generated CRDs, and selected trusted
instances have been manually server-side dry-run/applied in dependency order.

## Folders and files to configure

| Location | Required action |
|---|---|
| `iac/csoc/profiles/dev.profile` | Retain the owned `js2-mgmt-cluster-2` state/kubeconfig paths and default-branch Git revisions. This file is tracked. |
| `iac/csoc/profiles/prod.profile` | Before any production create, review the immutable three-member `m3.quad` control plane, distinct state/kubeconfig paths, and `release/prod` revisions. This file is tracked. |
| `iac/magnum/cluster.env` | Review shared provider template, network, keypair, volume, and timeout settings. |
| `scripts/host/credentials/magnum-clouds.yaml` | Copy its example, insert a short-lived unrestricted Magnum-only application credential, and set mode `0600`. |
| `scripts/host/credentials/accounts/<identity>/clouds.yaml` | Create one different restricted credential per active spoke account, even when it uses the same project as CSOC; set mode `0600`. |
| `js-poc-csoc-fleet/accounts/kustomization.yaml` | List only account directories that should be actively reconciled. An empty list creates no spokes. |
| `js-poc-csoc-fleet/accounts/<identity>/identity-config.yaml` | Set reviewed write-once account, compute, network, storage, load-balancer, and Kubernetes restrictions. Never put secret names or values here. |
| `js-poc-csoc-fleet/accounts/<identity>/identity.yaml` | Create the matching `SpokeIdentity`; its name selects the credential directory and account namespace. |
| `js-poc-csoc-fleet/accounts/<identity>/spoke-config.yaml` | Set write-once environment, node/pod/service CIDRs, MTU, DHCP, and port-security allocation inputs. |
| `js-poc-csoc-fleet/accounts/<identity>/network.yaml` | Select exactly one network RGD. Add `network-import-config.yaml` only for exact-ID import. |
| `js-poc-csoc-fleet/accounts/<identity>/cluster.yaml` | Set only mutable `minNodes` and `maxNodes`. |
| `js-poc-csoc-fleet/accounts/<identity>/hello-app.yaml` | Optional spoke Hello workload; public access is restricted by the immutable account `/32`. |
| `js-poc-csoc-fleet/csoc/hello-app.yaml` | CSOC-local `HelloApp` instance; normally retain the reviewed defaults. |
| `js-poc-csoc-app-catalog/rgds/test-poc/` | Review the tested OpenStack profile; Argo renders it only through `rgds/kustomization.yaml`. |

Start from `js-poc-csoc-fleet/examples/accounts/test-poc/`. Copy only the
selected network variant as `network.yaml`; do not activate all variants. The
example API CIDR and exact import UUIDs are deliberate non-working placeholders
and must be replaced before activation.

The development profile currently activates `accounts/test-poc` with one
`m3.small` control plane and `1..2` `m3.quad` workers. Its spoke API allow-list
is the exact reviewed shared-router SNAT `/32`. The production profile has no
fleet Application, so it deploys no CSOC or spoke instances.

## Immutable and mutable boundary

`ImmutableSpokeConfig` produces immutable ConfigMaps named
`<identity>-account-config`, `-compute-service-config`,
`-network-service-config`, `-storage-service-config`,
`-loadbalancer-service-config`, and `-kubernetes-config`. `SpokeIdentity`
copies them into `spokeclusters-<identity>`. `SpokeEnvironmentConfig` produces
immutable `<spoke>-network-config` and `<spoke>-cluster-config`; a network graph
produces immutable `<spoke>-connection`, and `SpokeKeypair` creates the Nova
keypair through ORC and publishes immutable `<spoke>-keypair-connection`.

Changing any write-once value is a replacement operation: retire the consuming
spoke, delete the affected graph/config instance after dependents are gone,
then create a new instance. Only `SpokeCluster.spec.kubernetes.minNodes` and
`maxNodes` are normal mutable fleet inputs.

## Ordered gate

1. Run `make validate`, `make security-scan`, `make container-build`, and
   `make preflight PROFILE=dev`; confirm the Magnum dry-run resolves only the provider-owned
   template.
2. Create/verify the Magnum CSOC and obtain its certificate kubeconfig.
3. Install Argo CD itself, then run `make argocd-manual-smoke`. The gate is
   tied to the selected profile and the exact fetched bootstrap, catalog, and
   enabled-fleet commit IDs; a later remote commit requires a new dry-run gate.
4. Run `make capi-secret PROFILE=dev IDENTITY=<identity>` for each active account. The
   loader verifies restriction, expiry, project match, and CSOC/spoke
   credential separation without printing credential values.
5. Run `make argocd-bootstrap PROFILE=dev`. The script archives the exact
   configured remote branches, then manually applies and waits for AppProjects,
   controllers, every RGD/CRD, CSOC Hello, and each listed account instance
   before it creates the Argo root Applications.
6. Accept each spoke only after CAPI readiness, Calico, CCM, Cinder CSI, PVC,
   autoscaling bounds, and its internal Hello response pass.

Deletion is not performed by removing YAML alone. Follow the spoke procedure
in [OPERATIONS.md](OPERATIONS.md).
