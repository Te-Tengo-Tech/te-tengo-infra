SHELL := /bin/bash
.DEFAULT_GOAL := help

# ----------------------------------------------------------------------------
# Terraform (bootstrap/, envs/, modules/) — docs/terraform.md
# ----------------------------------------------------------------------------

TF              ?= terraform
TF_DIRS         := bootstrap modules/te-tengo envs/mvp envs/local
MVP_DIR         := envs/mvp
LOCAL_DIR       := envs/local
ANSIBLE_DIR     := ansible

# Floci, the local AWS emulator. Host port 24566 so it does not clash with the API's own
# Floci on 4566 (te-tengo-general-api compose.yaml).
FLOCI_IMAGE     ?= floci/floci:2.2.0
FLOCI_CONTAINER ?= te-tengo-infra-floci
FLOCI_PORT      ?= 24566
FLOCI_ENDPOINT  ?= http://localhost:$(FLOCI_PORT)

TFLINT_IMAGE    ?= ghcr.io/terraform-linters/tflint:v0.64.0
CHECKOV_IMAGE   ?= bridgecrew/checkov:3.3.18

# Every local-* Terraform run drops any AWS credentials or profile from the environment and
# sends traffic that is not for localhost to a dead proxy (port 9), so a call that misses an
# endpoint override fails instead of reaching AWS.
LOCAL_ENV := env -u AWS_PROFILE -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
	HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=localhost,127.0.0.1 \
	TF_VAR_floci_endpoint=$(FLOCI_ENDPOINT) TF_IN_AUTOMATION=1

.PHONY: help fmt fmt-check validate lint security check \
	local-up local-down local-init local-plan local-apply local-destroy local-test \
	inventory mvp-init mvp-plan

help: ## List the targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

fmt: ## Format every Terraform file
	$(TF) fmt -recursive

fmt-check: ## Fail if a Terraform file is not formatted
	$(TF) fmt -recursive -check -diff

validate: ## terraform validate every configuration (no backend, no AWS calls)
	@set -e; for dir in $(TF_DIRS); do \
		echo "==> $$dir"; \
		$(TF) -chdir=$$dir init -backend=false -input=false >/dev/null; \
		$(TF) -chdir=$$dir validate; \
	done

lint: ## tflint (terraform + aws rulesets) through Docker
	docker run --rm -v "$(CURDIR):/data" -w /data \
		-v te-tengo-tflint-plugins:/plugins -e TFLINT_PLUGIN_DIR=/plugins \
		--entrypoint sh $(TFLINT_IMAGE) -c \
		'tflint --init --config /data/.tflint.hcl >/dev/null && tflint --recursive --config /data/.tflint.hcl --format compact'

security: ## checkov static analysis through Docker
	docker run --rm -v "$(CURDIR):/data" -w /data $(CHECKOV_IMAGE) -d /data --config-file /data/.checkov.yaml

check: fmt-check validate lint security ## Every static check

local-up: ## Start the Floci emulator on $(FLOCI_PORT) and wait until it is healthy
	@if ! docker inspect -f '{{.State.Running}}' $(FLOCI_CONTAINER) 2>/dev/null | grep -q true; then \
		docker run -d --rm --name $(FLOCI_CONTAINER) -p $(FLOCI_PORT):4566 \
			-e FLOCI_SERVICES_ECS_RECONCILE_CONTAINERS_ON_STARTUP=false $(FLOCI_IMAGE) >/dev/null; \
	fi
	@for i in $$(seq 1 60); do \
		curl -fsS -o /dev/null $(FLOCI_ENDPOINT)/_localstack/health 2>/dev/null && { echo "Floci is up at $(FLOCI_ENDPOINT)"; exit 0; }; \
		sleep 1; \
	done; echo "Floci did not become healthy" >&2; exit 1

local-down: ## Stop Floci (its state is in memory, so this wipes it) and remove the local state
	-docker rm -f $(FLOCI_CONTAINER) >/dev/null 2>&1
	rm -f $(LOCAL_DIR)/terraform.tfstate $(LOCAL_DIR)/terraform.tfstate.backup $(LOCAL_DIR)/tfplan

local-init:
	$(TF) -chdir=$(LOCAL_DIR) init -input=false >/dev/null

local-plan: local-init ## Plan envs/local against Floci
	$(LOCAL_ENV) $(TF) -chdir=$(LOCAL_DIR) plan -input=false -out=tfplan

local-apply: local-plan ## Apply envs/local against Floci
	$(LOCAL_ENV) $(TF) -chdir=$(LOCAL_DIR) apply -input=false tfplan
	@rm -f $(LOCAL_DIR)/tfplan

local-destroy: local-init ## Destroy envs/local in Floci
	$(LOCAL_ENV) $(TF) -chdir=$(LOCAL_DIR) destroy -input=false -auto-approve

local-test: local-up local-apply local-destroy ## Floci round trip: up, apply, destroy

inventory: ## Write ansible/inventory/hosts.yml from the envs/mvp outputs (ENV_DIR=envs/local for the emulator)
	@mkdir -p $(ANSIBLE_DIR)/inventory
	$(TF) -chdir=$(or $(ENV_DIR),$(MVP_DIR)) output -raw ansible_inventory > $(ANSIBLE_DIR)/inventory/hosts.yml
	@echo "Wrote $(ANSIBLE_DIR)/inventory/hosts.yml"

mvp-init: ## Init envs/mvp with the S3 backend (needs envs/mvp/backend.hcl and real AWS credentials)
	$(TF) -chdir=$(MVP_DIR) init -input=false -backend-config=backend.hcl

mvp-plan: ## Plan envs/mvp (real AWS; review before any apply, see docs/terraform.md)
	$(TF) -chdir=$(MVP_DIR) plan -input=false -out=tfplan
