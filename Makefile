.DEFAULT_GOAL := help
MAKEFLAGS     += --no-print-directory

IMAGE_NAME  ?= jetstream2-mgmt
IMAGE_TAG   ?= latest
OS_CLOUD    ?= openstack
PROFILE     ?= $(notdir $(abspath ..))
export JETSTREAM_IMAGE_NAME = $(IMAGE_NAME)
export JETSTREAM_IMAGE_TAG  = $(IMAGE_TAG)
export OS_CLOUD
export CSOC_PROFILE = $(PROFILE)

.PHONY: help \
	validate validate-clusters security-scan preflight \
	container-build container-run container-up container-shell container-status container-stop \
	containers-up containers-status containers-stop \
	magnum-templates magnum-provision magnum-wait magnum-kubeconfig \
	magnum-configure-nodegroup magnum-diagnose magnum-verify magnum-verify-autoscaling \
	csoc-plan csoc-resize clusters-verify clusters-verify-all \
	credential-create capi-secret \
	argocd-install argocd-manual-smoke argocd-bootstrap argocd-status \
	cmp-build cmp-verify v2-render-verify v2-server-dry-run v1-activate v2-activate v2-kind-compile \
	destroy-spoke \
	bootstrap

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

validate: ## Run non-destructive static validation
	bash scripts/tools/validate.sh

validate-clusters: ## Validate every CSOC profile and every declared spoke
	bash scripts/tools/validate-clusters.sh

security-scan: ## Scan publishable files for credential material
	bash scripts/tools/scan-secrets.sh

cmp-build: ## Build the pinned non-root SOPS/AGE Argo CMP image locally
	@set -a; . ./versions.env; set +a; \
	docker build --pull=false \
	  --build-arg HELM_VERSION="$${HELM_VERSION}" \
	  --build-arg SOPS_VERSION="$${SOPS_VERSION}" \
	  --build-arg AGE_VERSION="$${AGE_VERSION}" \
	  --build-arg KUSTOMIZE_VERSION="$${KUSTOMIZE_VERSION}" \
	  --build-arg YQ_VERSION="$${YQ_VERSION}" \
	  --tag csoc-sops-helm-cmp:0.1.0 cmp

cmp-verify: ## Verify local CMP user, tool pins, and embedded charts
	bash scripts/tools/validate-cmp-image.sh

v2-render-verify: ## Render supported v2 charts and compare AppProject/RBAC policy
	bash scripts/tools/validate-v2-renders.sh

v2-server-dry-run: ## Validate RGDs against an approved prepared controller API (non-persisting)
	bash scripts/tools/server-dry-run-v2.sh

v2-activate: ## Apply v2 RGDs and wait for Active GraphRevisions (explicitly gated)
	bash scripts/tools/activate-v2-rgds.sh

v1-activate: ## Apply v1 RGDs sequentially and wait for Active GraphRevisions (explicitly gated)
	bash scripts/tools/activate-v1-rgds.sh

v2-kind-compile: ## Compile both RGD generations in a retained local kind cluster (explicitly gated)
	bash scripts/tools/kind-compile-v2.sh

preflight: ## Run read-only OpenStack and ownership checks
	bash scripts/bootstrap/magnum/preflight.sh

# ── Container ────────────────────────────────────────────────────────────────
container-build: ## Build the management container image
	bash scripts/host/container/build.sh

container-run: ## Run the management container interactively
	bash scripts/host/container/run.sh

container-up: ## Start persistent operator container (PROFILE=dev|staging|prod)
	bash scripts/host/container/manage.sh up

container-shell: ## Open the profile operator container (PROFILE=dev|staging|prod)
	bash scripts/host/container/manage.sh shell

container-status: ## Show profile operator container status (PROFILE=dev|staging|prod)
	bash scripts/host/container/manage.sh status

container-stop: ## Stop profile operator container (PROFILE=dev|staging|prod)
	bash scripts/host/container/manage.sh stop

containers-up: ## Start one isolated operator container for every CSOC profile
	bash scripts/host/container/manage-all.sh up

containers-status: ## Show every profile operator container
	bash scripts/host/container/manage-all.sh status

containers-stop: ## Stop every profile operator container
	bash scripts/host/container/manage-all.sh stop

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

# ── Declarative CSOC changes ─────────────────────────────────────────────────
csoc-plan: ## Read-only diff of PROFILE IaC against its owned Magnum cluster
	bash scripts/operations/csoc/plan.sh

csoc-resize: ## Apply only reviewed worker bounds (CONFIRM=<cluster-name>)
	bash scripts/operations/csoc/reconcile-mutable.sh --confirm "$${CONFIRM:-}"

clusters-verify: ## Live readiness validation for one CSOC and all its spokes
	bash scripts/operations/csoc/verify-all.sh

clusters-verify-all: ## Run live validation in a container for every provisioned CSOC
	bash scripts/host/verify-all-clusters.sh

# ── CAPI ──────────────────────────────────────────────────────────────────────
credential-create: ## Create an app credential (EXPIRES_AT optional only for unrestricted policy)
	SOURCE_CLOUDS="$${SOURCE}" OUTPUT_CLOUDS="$${OUTPUT}" \
	CREDENTIAL_NAME="$${NAME}" CREDENTIAL_POLICY="$${POLICY:-restricted}" \
	CREDENTIAL_EXPIRES_AT="$${EXPIRES_AT}" \
	bash scripts/host/create-application-credential.sh

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
