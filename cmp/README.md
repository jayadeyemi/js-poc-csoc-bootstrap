# CSOC SOPS/AGE CMP

The image is built once, as a non-root sidecar, with exact Helm, SOPS, AGE,
Kustomize, and yq versions. JupyterHub and kube-prometheus-stack are embedded
at image build time; reconciliation performs no repository or binary downloads.

The upstream Jupyter-JSC index no longer publishes the plan-pinned Outpost
chart `2.1.2`. The API pin is retained, but outpost activation remains blocked
until that exact archive is recovered, checksummed, and added to
`/opt/csoc/charts`; the renderer fails closed instead of substituting 2.1.3 or
a newer chart.

Before any live Argo install, publish the image to the approved registry,
replace `CMP_IMAGE` and the Argo values image with its immutable digest, and
create the external `argocd/argocd-cmp-age-dev` Secret containing `keys.txt`.
Staging and production branches use distinct Secret names and AGE identities.

The renderer accepts only the `ARGOCD_ENV_` inputs enumerated in
`generate.sh`, requires a 40-character source revision, rejects path traversal,
and writes decrypted material only beneath the memory-backed `/tmp` mount.
