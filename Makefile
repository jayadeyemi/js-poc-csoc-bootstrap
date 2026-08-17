.DEFAULT_GOAL := help
MAKEFLAGS     += --no-print-directory

IMAGE_NAME  ?= jetstream2-mgmt
IMAGE_TAG   ?= latest
OS_CLOUD    ?= jetstream2
CLUSTER_DIR ?= iac/capi/clusters/example-cluster

export JETSTREAM_IMAGE_NAME = $(IMAGE_NAME)
export JETSTREAM_IMAGE_TAG  = $(IMAGE_TAG)
export OS_CLOUD

.PHONY: help \
	container-build container-run \
	magnum-provision magnum-wait magnum-kubeconfig \
	capi-install capi-secret capi-cluster \
	bootstrap

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ── Container ────────────────────────────────────────────────────────────────
container-build: ## Build the management container image
	bash scripts/container/build.sh

container-run: ## Run the management container interactively
	bash scripts/container/run.sh

# ── Magnum ────────────────────────────────────────────────────────────────────
magnum-provision: ## Idempotently provision the Magnum management cluster
	bash scripts/magnum/provision.sh

magnum-wait: ## Wait for the Magnum cluster to become active
	bash scripts/magnum/wait.sh

magnum-kubeconfig: ## Fetch and merge the Magnum cluster kubeconfig
	bash scripts/magnum/kubeconfig.sh

# ── CAPI ──────────────────────────────────────────────────────────────────────
capi-install: ## Install CAPI + CAPO controllers on the management cluster
	bash scripts/capi/install-controllers.sh

capi-secret: ## Create/update the OpenStack cloud secret for CAPO
	bash scripts/capi/create-cloud-secret.sh

capi-cluster: ## Provision a workload cluster (set CLUSTER_DIR to override)
	bash scripts/capi/provision-cluster.sh $(CLUSTER_DIR)

# ── Full pipeline ─────────────────────────────────────────────────────────────
bootstrap: ## Full orchestration: container → Magnum → CAPI → workload cluster
	bash scripts/bootstrap.sh $(CLUSTER_DIR)
