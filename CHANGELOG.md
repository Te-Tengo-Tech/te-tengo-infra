# Changelog

Format based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/); the project uses [semantic versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-10-08

First release: everything needed to create the Te Tengo production host, configure it and deploy the backend on it.

### Added

- **Terraform, Azure (active):** `modules/te-tengo-azure` and `envs/azure` create one `Standard_B2ats_v2` VM (2 vCPU / 1 GiB, Ubuntu 24.04 x64, Trusted Launch) in `chilecentral` on the Azure for Students subscription, with a static public IP, a minimal virtual network and an NSG open on 80, 443 (TCP+UDP) and 8322, SSH key-only from `admin_cidrs`. It renders the Ansible inventory and is tested offline with a mocked provider. State in Cloudflare R2 through the S3 backend (or local). First deploy to the VM on 2026-10-08.
- **Terraform, inactive alternatives** (kept validated, linted and tested in CI, never applied): `envs/oci` + `modules/te-tengo-oci`, one Ampere A1 VM on OCI Always Free (dropped for lack of A1 capacity); `envs/mvp` + `modules/te-tengo` + `bootstrap/`, the same host on AWS EC2 `t4g.small`, "VM only" by default (S3, SES, SNS and Route53 optional), verified against the Floci emulator through `envs/local`.
- **Ansible roles** (`ansible/site.yml`, over plain SSH on Azure/OCI or SSH over SSM on AWS): `base` (unattended upgrades, journald cap, swap and sysctl by memory profile, the OCI image firewall on OCI only, extra authorized keys such as the deploy key), `docker` (Docker Engine, Buildx and Compose from Docker's apt repository, log rotation), `app` (validates the settings and the vault, renders the Compose stack and its env files, gets the API image from GHCR, an archive or a build, starts the stack and checks it over HTTPS; `te_tengo_api_tag: current` keeps the deployed image) and `backup`.
- **Docker Compose stack** (`compose/`): Caddy (Let's Encrypt, HSTS), `te-tengo-general-api`, PostgreSQL 18 on an internal network and MediaMTX for the live view (RTSPS on 8322 with Caddy's certificate, LL-HLS behind Caddy under `/vivo/`, authorization through the API, browser origins restricted with `te_tengo_hls_allow_origins`). Memory profiles from `tiny` (1 GiB Azure default) to `large`, measured on a 1 GiB test host and on the real VM.
- **Cloudflare R2 storage and backups:** clips, database dumps and the Terraform state in R2; daily `pg_dump` at 03:30 Lima (last 7 kept on the host, every dump copied to R2) and `te-tengo-restore` from a local file, an R2 object or `latest`. E-mail through a generic SMTP relay and push through Firebase Cloud Messaging.
- **Continuous deployment with approval** (`deploy.yml`): `repository_dispatch` `desplegar-api` from `te-tengo-general-api`, a push to `main` touching `ansible/**` or `compose/**` (configuration-only redeploy with the current image), or a manual run. Production runs wait for a required reviewer on the `produccion` environment, then run the app role over SSH with a pinned host key and the committed, non-secret `ansible/prod.yml`, and check `/actuator/health`.
- **CI and local tests:** `terraform.yml` (fmt, validate, `terraform test` with mocked providers, tflint, checkov) and `ansible.yml` (yamllint, ansible-lint, syntax check, `docker compose config`, deploy to a containerized Ubuntu 24.04 host with Floci as the R2 stand-in plus a smoke test); `make test-all` runs the same locally without a cloud account.
- **Documentation:** README, `docs/terraform.md` (resources, costs, runbooks), `docs/ansible.md`, `docs/deploy.md` (runbook, CD, secrets inventory, rollback) and `docs/interface-terraform-ansible.md` (the inventory contract).
