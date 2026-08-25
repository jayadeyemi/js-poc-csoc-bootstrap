---
description: >
  Load a restricted spoke credential, manually apply controller and KRO waves,
  then hand the accepted resources to the rgds and csoc-fleet projects.
tools:
  - run_in_terminal
---

# Spoke credential and manual-first Argo bootstrap

Magnum and KRO have separate responsibilities and separate credentials:

- Magnum uses `scripts/host/credentials/magnum-clouds.yaml` only to create the
  CSOC management cluster. The resulting cluster appears in Horizon under
  Container Infrastructure.
- CAPO, ORC, OpenStack CCM, and Cinder CSI use the restricted credential at
  `scripts/host/credentials/accounts/test-poc/clouds.yaml`. KRO creates
  the graphs and CAPO provisions spoke servers, networks, and load balancers;
  a spoke is not a Magnum cluster and does not appear in Horizon's Container
  Infrastructure cluster list.

The two application credential IDs must differ even when both credentials
target the same OpenStack project. Never load the Magnum credential into a
Kubernetes Secret.

## 1. Load the spoke credential

```bash
KUBECONFIG=.state/kubeconfigs/config \
  bash scripts/bootstrap/credentials/create-runtime-cloud-secret.sh test-poc
```

The loader verifies that the credential is restricted, unexpired, and scoped
to the trusted project in `fleet/accounts/test-poc`. It creates only:

- `test-poc-cloud-config` in `spokeclusters-test-poc` for CAPO/ORC;
- `test-poc-workload-cloud-config` in that namespace for CCM/CSI addons.

It never prints credential values.

## 2. Run the manual-first bootstrap

```bash
KUBECONFIG=.state/kubeconfigs/config \
  bash scripts/bootstrap/argocd/bootstrap-apps.sh
```

The script applies and waits in this order:

1. AppProjects `rgds` and `csoc-fleet`;
2. controller Applications and their CRDs;
3. KRO RGD definitions and generated CRDs;
4. the CSOC-local `CSOCHelloApp/csoc` instance and fleet instances under
   `accounts/test-poc`, beginning with `ImmutableSpokeConfig/test-poc` and
   `SpokeIdentity/test-poc`;
5. the controller, RGD, fleet, and root Applications. No ApplicationSet is used.

The immutable account config approves one general worker flavor. Per-cluster
`minNodes` and `maxNodes` remain mutable only on `SpokeCluster`; there are no
GPU, high-memory, or worker-class selector fields.

Do not bypass these readiness gates or allow Argo pruning during an RGD
ownership transfer.

The CSOC and spoke Hello Services must retain the OpenStack internal-load-
balancer annotation. They must not attach a floating IP or reuse either
cluster's Kubernetes API load balancer.

## 3. Verify identity isolation and ownership

```bash
kubectl get openstackclusteridentity test-poc -o yaml
kubectl get secret -n spokeclusters-test-poc \
  test-poc-cloud-config test-poc-workload-cloud-config
kubectl get applications -n argocd
kubectl get appprojects -n argocd
```

The identity selector must match only namespaces labeled
`csoc.js2.org/identity=test-poc`. Exactly the two intended AppProjects
must remain after legacy ownership is retired.

## Horizon expectations

For the CSOC cluster, use Horizon **Container Infrastructure → Clusters**. For
a CAPO spoke, use **Compute → Instances**, **Network → Networks/Ports**, and
**Network → Load Balancers**. The management-cluster CAPI objects are also
visible with `kubectl get cluster,openstackcluster,machine -A`.
