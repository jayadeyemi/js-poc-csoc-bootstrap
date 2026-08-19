.DEFAULT_GOAL := help
MAKEFLAGS     += --no-print-directory

IMAGE_NAME  ?= jetstream2-mgmt
IMAGE_TAG   ?= latest
OS_CLOUD    ?= openstack
export JETSTREAM_IMAGE_NAME = $(IMAGE_NAME)
export JETSTREAM_IMAGE_TAG  = $(IMAGE_TAG)
export OS_CLOUD

.PHONY: help \
	validate security-scan preflight \
	container-build container-run \
	magnum-templates magnum-provision magnum-wait magnum-kubeconfig \
	capi-secret \
	argocd-install argocd-bootstrap argocd-status \
	bootstrap

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

validate: ## Run non-destructive static validation
	bash scripts/validate.sh

security-scan: ## Scan publishable files for credential material
	bash scripts/security/scan-secrets.sh

preflight: ## Run read-only OpenStack and ownership checks
	bash scripts/magnum/preflight.sh

# ── Container ────────────────────────────────────────────────────────────────
container-build: ## Build the management container image
	bash scripts/container/build.sh

container-run: ## Run the management container interactively
	bash scripts/container/run.sh

# ── Magnum ────────────────────────────────────────────────────────────────────
magnum-templates: ## Save a timestamped inventory of visible Magnum templates
	bash scripts/magnum/inventory-templates.sh

magnum-provision: ## Idempotently provision the Magnum management cluster
	bash scripts/magnum/provision.sh

magnum-wait: ## Wait for the Magnum cluster to become active
	bash scripts/magnum/wait.sh

magnum-kubeconfig: ## Fetch and merge the Magnum cluster kubeconfig
	bash scripts/magnum/kubeconfig.sh

# ── CAPI ──────────────────────────────────────────────────────────────────────
capi-secret: ## Create/update the OpenStack cloud secret for CAPO
	bash scripts/capi/create-cloud-secret.sh

# ── Argo CD ────────────────────────────────────────────────────────────────
argocd-install: ## Install Argo CD via Helm on the management cluster
	bash scripts/argocd/install.sh

argocd-bootstrap: ## Apply App-of-Apps and hand off cluster to GitOps
	bash scripts/argocd/bootstrap-apps.sh

argocd-status: ## Show all Argo CD Application sync status
	kubectl get applications -n argocd

# ── Full pipeline ────────────────────────────────────────────────────
bootstrap: ## Full orchestration: container → Magnum → CAPI → Argo CD → GitOps
	bash scripts/bootstrap.sh
