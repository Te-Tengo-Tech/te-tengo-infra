# ----------------------------------------------------------------------------
# Ansible + Docker Compose (ansible/, compose/, test/) — docs/ansible.md, docs/deploy.md
# Included by the Makefile.
# ----------------------------------------------------------------------------

ANSIBLE_DIR     ?= ansible
VAULT_ARGS      ?= --ask-vault-pass
# Extra arguments for ansible-playbook, e.g. ANSIBLE_ARGS="-e te_tengo_api_tag=sha-0123abc --diff"
ANSIBLE_ARGS    ?=
# Local te-tengo-general-api checkout the test image is built from.
TT_API_SRC      ?= $(abspath ../te-tengo-general-api)
TEST_COMPOSE    := docker compose -f test/compose.yaml
TEST_PLAYBOOK   := cd $(ANSIBLE_DIR) && ansible-playbook site.yml -i ../test/inventory.yml \
	-e @../test/vars.yml -e @../test/.work/vault.yml

.PHONY: galaxy ansible-lint yamllint compose-config ansible-check deploy redeploy backup-now \
	test-host-up test-image test-deploy test-smoke test-down test-all

galaxy: ## Install the Ansible collections (requirements.yml)
	cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r requirements.yml

ansible-lint: ## ansible-lint (production profile) on the playbook and roles
	cd $(ANSIBLE_DIR) && ansible-lint site.yml

yamllint: ## yamllint on the Ansible, Compose and test YAML
	yamllint -s ansible compose test .github/workflows

compose-config: ## Validate compose/compose.yaml with the example env files
	@set -e; tmp=$$(mktemp -d); trap 'rm -rf $$tmp' EXIT; \
	cp compose/compose.yaml compose/compose.build.yaml $$tmp/; \
	cp compose/.env.example $$tmp/.env; cp compose/api.env.example $$tmp/api.env; \
	docker compose --project-directory $$tmp -f $$tmp/compose.yaml config --quiet; \
	API_BUILD_CONTEXT=. docker compose --project-directory $$tmp -f $$tmp/compose.yaml -f $$tmp/compose.build.yaml config --quiet; \
	docker compose -f test/compose.yaml config --quiet; \
	echo "compose files are valid"

ansible-check: yamllint ansible-lint compose-config ## Every static check of the Ansible side

deploy: ## Full playbook against ansible/inventory/hosts.yml (real host; docs/deploy.md)
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml $(VAULT_ARGS) $(ANSIBLE_ARGS)

redeploy: ## Only the app role (new image tag or configuration)
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml --tags app $(VAULT_ARGS) $(ANSIBLE_ARGS)

backup-now: ## Run the backup job on the host now
	cd $(ANSIBLE_DIR) && ansible te_tengo --become -m ansible.builtin.systemd_service \
		-a "name=te-tengo-backup.service state=started" $(VAULT_ARGS)

# --- Local test host (no AWS) -------------------------------------------------

test-host-up: ## Start the test host (Ubuntu 24.04 + systemd) and Floci, then throwaway secrets and buckets
	$(TEST_COMPOSE) up -d --build --wait
	test/prepare.sh

test-image: ## Build the API image from TT_API_SRC and save it to test/.work
	TT_API_SRC="$(TT_API_SRC)" test/build-api-image.sh

test-deploy: test-image ## Run the whole site.yml against the test host
	$(TEST_PLAYBOOK) $(ANSIBLE_ARGS)

test-smoke: ## Smoke test from the Mac through Caddy (HTTPS, sign-in, clips on Floci, HLS 401, backup/restore)
	test/smoke.sh

test-down: ## Remove the test host, Floci and their volumes
	$(TEST_COMPOSE) down --volumes --remove-orphans
	rm -rf test/.work

test-all: test-host-up test-deploy test-smoke ## Up, deploy and smoke test in one go
