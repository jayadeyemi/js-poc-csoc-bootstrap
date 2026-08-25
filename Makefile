.DEFAULT_GOAL := help
MAKEFLAGS     += --no-print-directory

IMAGE_NAME  ?= jetstream2-mgmt
IMAGE_TAG   ?= latest
OS_CLOUD    ?= openstack
PROFILE     ?= dev
export JETSTREAM_IMAGE_NAME = $(IMAGE_NAME)
export JETSTREAM_IMAGE_TAG  = $(IMAGE_TAG)
export OS_CLOUD
export CSOC_PROFILE = $(PROFILE)

.PHONY: help \
	validate security-scan preflight \
	container-build container-run container-up container-shell container-status container-stop \
	magnum-templates magnum-provision magnum-wait magnum-kubeconfig \
	magnum-configure-nodegroup magnum-diagnose magnum-verify magnum-verify-autoscaling \
	capi-secret \
	argocd-install argocd-manual-smoke argocd-bootstrap argocd-status \
	destroy-spoke \
	bootstrap

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

validate: ## Run non-destructive static validation
	bash scripts/tools/validate.sh

security-scan: ## Scan publishable files for credential material
	bash scripts/tools/scan-secrets.sh

preflight: ## Run read-only OpenStack and ownership checks
	bash scripts/bootstrap/magnum/preflight.sh

# ── Container ────────────────────────────────────────────────────────────────
container-build: ## Build the management container image
	bash scripts/host/container/build.sh

container-run: ## Run the management container interactively
	bash scripts/host/container/run.sh

container-up: ## Start persistent operator container (PROFILE=dev|prod)
	bash scripts/host/container/manage.sh up

container-shell: ## Open the profile operator container (PROFILE=dev|prod)
	bash scripts/host/container/manage.sh shell

container-status: ## Show profile operator container status (PROFILE=dev|prod)
	bash scripts/host/container/manage.sh status

container-stop: ## Stop profile operator container (PROFILE=dev|prod)
	bash scripts/host/container/manage.sh stop

# ── Magnum ────────────────────────────────────────────────────────────────────
magnum-templates: ## Save a timestamped inventory of visible Magnum templates
	bash scripts/operations/magnum/inventory-templates.sh

magnum-provision: ## Idempotently provision the Magnum management cluster
	bash scripts/bootstrap/magnum/provision.sh

magnum-wait: ## Wait for the Magnum cluster to become active
	bash scripts/bootstrap/magnum/wait.sh

magnum-configure-nodegroup: ## Reconcile default worker API bounds after create
	bash scripts/bootstrap/magnum/configure-nodegroup.sh

magnum-kubeconfig: ## Fetch and merge the Magnum cluster kubeconfig
	bash scripts/bootstrap/magnum/kubeconfig.sh

magnum-diagnose: ## Capture a redacted read-only Magnum support bundle
	bash scripts/operations/magnum/diagnose.sh

magnum-verify: ## Verify guide-exact management-cluster readiness
	bash scripts/bootstrap/magnum/verify.sh

magnum-verify-autoscaling: ## Exercise management workers within bounds
	bash scripts/bootstrap/magnum/verify-autoscaling.sh

# ── CAPI ──────────────────────────────────────────────────────────────────────
capi-secret: ## Load/update restricted CAPO/ORC and workload secrets (IDENTITY=test-poc)
	bash scripts/bootstrap/credentials/create-runtime-cloud-secret.sh $${IDENTITY:-test-poc}

# ── Spoke lifecycle ───────────────────────────────────────────────────────────
destroy-spoke: ## Retire a Git-removed spoke (IDENTITY=test-poc SPOKE=poc-tenant-dev)
	bash scripts/operations/spokes/destroy-spoke.sh \
	  --identity $${IDENTITY:-test-poc} \
	  --spoke $${SPOKE} \
	  --confirm $${SPOKE}

# ── Argo CD ────────────────────────────────────────────────────────────────
argocd-install: ## Install Argo CD via Helm on the management cluster
	bash scripts/bootstrap/argocd/install.sh

argocd-manual-smoke: ## Manually validate manifests before Argo reconciliation
	bash scripts/bootstrap/argocd/manual-smoke-test.sh

argocd-bootstrap: ## Apply App-of-Apps and hand off cluster to GitOps
	bash scripts/bootstrap/argocd/bootstrap-apps.sh

argocd-status: ## Show all Argo CD Application sync status
	kubectl get applications -n argocd

# ── Full pipeline ────────────────────────────────────────────────────
bootstrap: ## Full orchestration: container → Magnum → CAPI → Argo CD → GitOps
	bash scripts/host/bootstrap.sh
