# Changelog

Format based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/); the project uses [semantic versioning](https://semver.org/).

## [Unreleased]

Object storage moves from Cloudflare R2 to **Azure Blob Storage**, so the whole cloud side is Azure. Push stays on Firebase Cloud Messaging. The public downloads bucket on `r2.dev` (`TT_VERSIONES_URL_BASE`) is not part of this change and is the remaining R2 dependency.

### Added
- Ansible (`prod.yml`): `TT_MOVIMIENTOS_VERSION_TEXTO: "3"` in the API settings, the movements consent text that names Microsoft Azure as the cloud store (te-tengo-mobile-flutter `versionTextoMovimientos = '3'`); consents given with version 2 stay in force
- Terraform (`modules/te-tengo-azure/storage.tf`): a storage account `tetengo<environment><storage_account_suffix>` (`tetengoproddata`; StorageV2, Standard_LRS, hot, TLS 1.2, HTTPS only, no public blob access, **shared key access disabled**, no local users or SFTP, one-day SAS expiration policy, `prevent_destroy`) with the private containers `clips`, `movements` and `backups`. No blob versioning and no blob soft delete, so a clip deleted on consent revocation or retention is really gone (the S3 module's reasoning); 7-day container soft delete. A lifecycle policy deletes dumps after `backups_retention_days` (30) and clips only when `clips_retention_days` is set (default `null`, pending team decision). A blob CORS rule from `storage_cors_allowed_origins` (GET, HEAD, PUT, OPTIONS; `content-type`, `x-ms-blob-type`) for the PWA.
- A **system-assigned managed identity** on the VM, with Storage Blob Data Contributor on each container and Storage Blob Delegator on the account (user delegation SAS); the operator (`az login` identity) gets Storage Blob Data Contributor on the account (`grant_operator_storage_access`, default `true`). `Microsoft.Storage` is registered by the provider, which runs with `storage_use_azuread = true`.
- Module variables `storage_account_suffix`, `storage_cors_allowed_origins`, `backups_retention_days`, `clips_retention_days`, `grant_operator_storage_access`; outputs `storage_account_name`, `storage_account_id`, `storage_blob_endpoint`, `clips_container_name`, `movements_container_name`, `backups_container_name`, `vm_principal_id` (also in `envs/azure`). `terraform test` covers them (24 Azure runs).
- `bootstrap-azure/`: one-time root with local state for the Terraform state account (`tetengotfstate`, container `tfstate`, versioning and 90-day soft delete, the operator's data role), validated by `make validate` and watched by Dependabot.
- Ansible: `te_tengo_object_storage_provider` (inventory `object_storage_provider`: `azure`, the default on `cloud_provider: azure`, or `s3`), `te_tengo_object_storage_auth` (`managed_identity`, the default on Azure, or `static` with `vault_azure_storage_account_key` for the Azurite test host; `static`/`instance_role` for S3), `te_tengo_azure_storage_endpoint`, `te_tengo_azure_storage_account`, `te_tengo_clips_container`, `te_tengo_movements_container`, `te_tengo_backups_container` and `te_tengo_photos_container`. The app role writes `TT_ALMACENAMIENTO_PROVEEDOR`, `TT_AZURE_STORAGE_ENDPOINT`, `TT_AZURE_STORAGE_CUENTA`, `TT_AZURE_STORAGE_CLAVE` (static only), `TT_CLIPS_CONTENEDOR`, `TT_MOVIMIENTOS_CONTENEDOR` and `TT_FOTOS_CONTENEDOR`, and validates them. `ansible/prod.yml` pins `azure` and `managed_identity`.
- Backup role on Azure: `azcopy` from Microsoft's signed apt repository (packages.microsoft.com), dumps to `backups/postgres/` as the managed identity (`AZCOPY_AUTO_LOGIN_TYPE=MSI`; small buffers for the 1 GiB VM), the same schedule and local retention (last 7); `te-tengo-restore latest` downloads the newest dump from the container, and the new `te-tengo-restore list` lists them. The S3 path (AWS CLI) stays for the inactive OCI and AWS alternatives.
- docs/deploy.md: runbook "Migrate from Cloudflare R2 to Azure Blob"; docs/terraform.md: "Remote state on Azure" and the Blob Storage costs (no free egress, unlike R2).

### Changed
- `envs/azure` keeps its state in Azure Blob Storage: `backend "azurerm"` with `use_azuread_auth = true` (`backend.hcl.example`) instead of `backend "s3"` on R2.
- The Azure inventory renders `object_storage_provider: azure`, `object_storage_auth: managed_identity`, `azure_storage_endpoint`, `azure_storage_account`, `clips_container`, `movements_container` and `backups_container` instead of the S3 keys (docs/interface-terraform-ansible.md). The OCI and AWS inventories are unchanged.
- The local test harness uses **Azurite** (`mcr.microsoft.com/azure-storage/azurite:3.37.0`, fixed address `10.231.0.10`, published on 31000) instead of Floci, with Azurite's published development key (`object_storage_auth: static`), so the production-shaped path is the Azure one. The smoke test checks the SAS upload URL, the `x-ms-blob-type: BlockBlob` and `Content-Type` instructions, the upload with them and the blob in `clips`, `api.env` (Azure settings, no S3 settings or AWS credentials) and the backup and restore through the `backups` container with azcopy.

### Removed
- The R2 variables of `envs/azure` and `modules/te-tengo-azure`: `object_storage_endpoint`, `object_storage_region`, `object_storage_path_style`, `clips_bucket_name`, `backups_bucket_name`. Production no longer needs the R2 tokens (`vault_clips_s3_*`, `vault_backup_s3_*`, the `[r2-tfstate]` profile); they stay documented for the inactive OCI alternative and are revoked after the migration.

### Migration
Not applied yet. Order: (1) a te-tengo-general-api release with Azure support (it defaults to `s3`, so it keeps using R2); (2) `bootstrap-azure` and `terraform init -migrate-state` for the state; (3) `terraform apply` of `envs/azure` (10 to add, the VM updated in place) and up to 10 minutes for the role assignments; (4) copy the data (`aws s3 sync` from R2, `azcopy copy` to the containers, `movimientos/` keys to `movements`; or `rclone copy`); (5) update `ANSIBLE_INVENTORY` right before (6) the deploy of this release; (7) a second copy pass; (8) checks; (9) after a week, revoke the R2 tokens and delete the old buckets. Exact commands: docs/deploy.md, "Migrate from Cloudflare R2 to Azure Blob". Version 2 of the consent text shown to families (API `TT_MOVIMIENTOS_VERSION_TEXTO`) names Cloudflare R2 as the cloud store: a new text version is a product and legal decision, not taken here.

### Fixed
- MediaMTX's authorization hook carried the shared secret in a `?secreto=` query parameter, and MediaMTX logs the whole hook URL when a call fails (`HTTP request failed: Post "http://api:8080/api/interno/mediamtx/autorizar?secreto=…": context deadline exceeded`, production, 2026-10-24). `MTX_AUTHHTTPADDRESS` now carries it as the password of the URL's user info (`http://mediamtx:<secret>@api:8080/…`), which Go's HTTP client sends as an `Authorization: Basic` header and writes as `***` in errors. It needs te-tengo-general-api with Basic support deployed first, and the leaked value must be rotated afterwards (docs/deploy.md, «Rotate the MediaMTX hook secret»). The smoke test checks that no MediaMTX or API log line contains the secret, and `mediamtx.yml` documents that `readTimeout` (10 s) is also the hook's timeout and why it stays.
- The weekly branch cleanup listed each branch's pull requests with `gh api -f`, which sends a POST to the create-pull-request endpoint, so every lookup failed with 422 and the open-PR and `do-not-delete` protections were never checked. It now lists with `--method GET`, and a branch whose PRs cannot be read is left alone.

## [0.3.0] - 2026-10-11

### Added
- `TT_VERSIONES_URL_BASE` in `te_tengo_api_settings` (`ansible/prod.yml`): the API reads the published app versions (US-43, `GET /api/versiones`) from the manifests the desktop and mobile release workflows write to the downloads bucket, so a release no longer needs a change of `TT_AGENTE_VERSION_PUBLICADA` here (it stays as the fallback).

## [0.2.3] - 2026-10-10

### Security
- A manual run of `ansible.yml` no longer takes an `api_ref`: it always builds te-tengo-general-api's `develop`, so a dispatch cannot run an arbitrary branch's code in the default branch's context (CodeQL `actions/cache-poisoning/poisonable-step`, 6 alerts).

### Added
- A weekly `branch-cleanup.yml` (Mondays 04:00 UTC, or by hand with a dry run) deletes branches merged 7+ days ago and unmerged branches with no commits for 30+ days; it never touches `main`, `develop`, `release/*`, `hotfix/*`, branches with an open pull request or pull requests labelled `do-not-delete`, and `BRANCH_CLEANUP_ENABLED=false` turns it off.

### Fixed
- The back-merge job of `produccion.yml` runs whenever the release job succeeded, even if a switched-off job earlier in its chain was skipped (GitHub skips a job whose implicit `success()` sees a skipped ancestor; te-tengo-mobile-flutter 0.3.2 lost its back-merge that way).

## [0.2.2] - 2026-10-10

### Changed
- An infra release (and its rollback) deploys the **whole `site.yml`** (base, docker, app and backup; every role is idempotent), the same playbook its verification ran on the containerized host. A base-role change (zswap, masked services, firewall, swap) now reaches the VM with its release; hotfix 0.2.1's needed an operator's `--tags base`. API image deploys (`desplegar-api`) still run only the app role. `deploy.yml` takes a `roles` input (`app` or `all`).
- One production deploy at a time is now enforced by `.github/scripts/deploy-lock.sh`, the first step of the deploy job, which runs only after the `produccion` approval, instead of the job's concurrency group: a job holds its group while it waits for reviewers, so an API deploy dispatched behind an unapproved infra release stayed queued, and a third request cancelled the waiting one. `produccion.yml` and `rollback.yml` lost their workflow-level `produccion` group for the same reason.
- After the health check, the deploy job checks on the VM that the `api` container runs the configured image and, for an image deploy, the requested digest (`.github/scripts/check-deployed-image.sh`); te-tengo-general-api tags a release only after that.
- `produccion.yml` tags `vX.Y.Z` only after the configuration was deployed (not when `ENABLE_API_DEPLOY` is off, nor when `main` moved on meanwhile), finds its candidate with `.github/scripts/find-candidate.sh` (the same search as the release gate) and opens the back-merge as the GitHub App te-tengo-release-bot with auto-merge; after a hotfix it also opens `main → release/*` for newer release branches.
- The release pull request is opened by te-tengo-release-bot instead of `GITHUB_TOKEN`, so its checks run. A release branch whose name differs from `VERSION` is an error.
- CI is one workflow, `ci.yml` (required check `ci-ok`), with `ansible.yml` and `terraform.yml` as reusable parts: on pull requests the parts whose files changed, on pushes to `develop` both, and once on each release commit (called by `release.yml`, which no longer repeats the static checks). Nothing runs again on pushes to `main`, `release/**` or `hotfix/**`.
- The containerized deploy test of pull requests runs for real: it checks out te-tengo-general-api with the workflow token (a public repository) instead of skipping itself without the `API_REPO_TOKEN` secret. It also runs the new `make test-running-image`.

### Added
- `release-gate.yml` (required check `release-gate` on `main`) and `pr-title.yml` (required check `pr-title`, Conventional Commits titles).
- Dependabot: GitHub Actions, Terraform (`bootstrap`, `envs/*`, `modules/*`), the Compose files of `compose/` and `test/`, and the test host's base image.
- docs/deploy.md: release gate, deploy lock, running-image check, rollback rehearsal.

### Removed
- The inactive `oci` and `aws` targets of `deploy.yml` (and its AWS OIDC job): a manual run would have created an unprotected `oci` or `mvp` environment, and every caller requested `id-token: write` only for that job. Those hosts are deployed with `make deploy`.

### Security
- Every action is pinned by commit SHA; no permissions at workflow level and the minimum per job.

## [0.2.1] - 2026-10-10

Hotfix for memory pressure on the 1 GiB Azure VM. The production audit of 2026-10-10 found 836 MiB of usable RAM, about 560 MB in swap with constant swap-in, the kernel reporting memory pressure, a 74 s stall of API threads, zswap off, unused host services running, and Caddy at its 64 MB cap. The product owner chose free tuning over a VM resize.

### Fixed

- **zswap on the host** (base role, `base_manage_zswap`, default `true`). zswap is a compressed cache in RAM in front of the swap file ([kernel docs](https://docs.kernel.org/admin-guide/mm/zswap.html)), so most swap-ins become decompressions instead of Standard SSD reads.
  - Ubuntu 24.04's linux-azure kernels (6.8 and 7.0) build it in but leave it off.
  - The new oneshot unit `te-tengo-zswap.service` writes the sysfs parameters at every boot: `zpool=zsmalloc` where the parameter exists, the first compressor the kernel accepts out of `zstd`, `lz4` and `lzo`, `max_pool_percent=20`, the shrinker on, then `enabled=Y`. Ansible enables and starts it, so zswap is on at once, with no reboot and no kernel command-line change.
  - Skipped when the kernel has no `/sys/module/zswap/parameters` and on the local test host, which shares the kernel of Docker's VM or of the CI runner (`test/vars.yml`).
- **Unused host services disabled and masked on Azure and OCI** (base role, `base_disable_unused_services`): `multipathd.socket`, `multipathd.service`, `fwupd-refresh.timer`, `fwupd.service`, `ModemManager.service` and `udisks2.service`, only where the image has them. A missing unit is skipped. The VM has one OS disk and no data disks, so it uses no multipath device.
- **Caddy memory limit in the `tiny` profile raised from 64 MB to 96 MB.** Its cgroup peak had reached the 64 MB cap on the VM. The `tiny` container caps now add up to 880 MiB, within the 900 MiB budget that `make test-memory` enforces. The other profiles are unchanged.

### Changed

- **Desktop agent 0.4.1 published.** `ansible/prod.yml` sets `TT_AGENTE_VERSION_PUBLICADA: "0.4.1"` in `te_tengo_api_settings`, so `GET /api/agente/configuracion` publishes 0.4.1 instead of the API's default (0.2.0).
- **Rollout.** The production redeploy after the merge runs only the `app` role: it applies the Caddy limit and the agent version. An operator applies the base-role changes (zswap, masked services) once with `make deploy ANSIBLE_ARGS="--tags base"`. The checks to run on the VM afterwards are in `docs/deploy.md` (section 5).

## [0.2.0] - 2026-10-09

### Added

- **Live view v3, WebRTC (WHEP) playback** with LL-HLS as the fallback (te-tengo-general-api ADR 0008). MediaMTX turns WebRTC on (`compose/mediamtx/mediamtx.yml`): WHEP signalling on 8889 inside the Docker network, served by Caddy at **`/vivo-webrtc/`** (prefix stripped, the WHEP session `Location` rewritten back under it, as in MediaMTX's "Expose the server in a subfolder"); media over one fixed ICE port, **8189 over UDP and TCP** (for networks that block UDP), published by Compose with the same number inside and outside; only the public address is announced (`webrtcIPsFromInterfaces: false`, `webrtcAdditionalHosts`); no STUN or TURN. Reads are authorized by the API's hook with the session's viewer token in the query (protocol `webrtc`), and browser origins are restricted like HLS (`webrtcAllowOrigins`).
- Ansible: `te_tengo_webrtc_port` (inventory `live_view_webrtc_port`, default 8189), `te_tengo_webrtc_additional_hosts` (inventory `public_ip` by default; `api.tetengo.reqsai.tech` in `prod.yml`), `te_tengo_webrtc_allow_origins` (the HLS origins; set in `prod.yml`) and `te_tengo_webrtc_enabled` (default `true`; `false` leaves `TT_VIVO_URL_WEBRTC` out of `api.env`, so the app keeps LL-HLS). The API gets `TT_VIVO_URL_WEBRTC=https://<host>/vivo-webrtc/camaras/{camaraId}/whep`; Compose gets `WEBRTC_ICE_PORT`, `WEBRTC_ALLOW_ORIGINS` and `WEBRTC_ADDITIONAL_HOSTS` (required). The app role validates them; the base role accepts 8189/UDP+TCP in the OCI image firewall.
- Terraform: `live_view_webrtc_port` (default 8189, 1024–65535) in the Azure, OCI and AWS modules. The Azure NSG gets `allow-webrtc_udp` (priority 150) and `allow-webrtc_tcp` (160) from anywhere, with the OCI security list and the AWS security group kept in parity. The inventory gains `live_view_webrtc_port`, and an output `live_view_webrtc_url_template` is added. `terraform test` covers the rules, the inventory and the port validation.
- Smoke test (`make test-smoke`): live view end to end through Caddy. An ffmpeg container publishes over RTSPS like the agent. WHEP answers `201` with an SDP answer announcing `127.0.0.1:8189` over UDP and TCP (no container address). The WHEP `Location` stays under `/vivo-webrtc/`, the CORS preflight works and `401` comes back without a token or once the session is closed. LL-HLS answers `200` with the token, and the ICE port is published over UDP and TCP.

## [0.1.1] - 2026-10-09

### Fixed

- `produccion.yml` and `rollback.yml` call `deploy.yml` with `secrets: inherit`; without it the called job in `produccion` did not receive the environment secrets (`ANSIBLE_VAULT_B64`, `ANSIBLE_VAULT_PASSWORD`, `DEPLOY_SSH_PRIVATE_KEY`) and the production redeploy of 0.1.0 failed before touching the host.

## [0.1.0] - 2026-10-09

### Added

- **Release flow** with release candidates (git flow, "build once, deploy many", tag at the end; Mermaid diagram in `docs/deploy.md`): `release.yml` on pushes to `release/**` and `hotfix/**` checks the release commit (`VERSION`, yamllint, ansible-lint, syntax check, `docker compose config`), verifies it on the containerized test host (`make test-all`; automatic, no environment: there is no staging target), records it as the pre-release `vX.Y.Z-rc.N` with its git tree hash and opens or updates the pull request to `main`; nothing is deployed from a release branch. On `main`, `produccion.yml` finds the verified candidate whose tree hash equals `main`'s (fails when `main` differs from what was verified), redeploys the configuration to production through `deploy.yml` (environment `produccion`, switch `ENABLE_API_DEPLOY`) and only then tags `vX.Y.Z` from `VERSION` with its GitHub Release and opens the back-merge pull request to `develop`. `rollback.yml` (manual) redeploys the configuration of an earlier release (`config_ref`).
- **`VERSION`** (0.1.0): the version source of the release pipeline.
- `ansible.yml` and `terraform.yml` also run on pushes to `release/**` and `hotfix/**`, since the release pull request opened with `GITHUB_TOKEN` starts no `pull_request` run; `ansible.yml` also runs on workflow changes (`make yamllint` lints them).
- **Switch** (organization variable, explicit opt-in): `ENABLE_API_DEPLOY` freezes production when it is not `true`.
- **Terraform, Azure (active):** `modules/te-tengo-azure` and `envs/azure` create one `Standard_B2ats_v2` VM (2 vCPU / 1 GiB, Ubuntu 24.04 x64, Trusted Launch) in `chilecentral` on the Azure for Students subscription, with a static public IP, a minimal virtual network and an NSG open on 80, 443 (TCP+UDP) and 8322, SSH key-only from `admin_cidrs`. It renders the Ansible inventory and is tested offline with a mocked provider. State in Cloudflare R2 through the S3 backend (or local). First deploy to the VM on 2026-10-08.
- **Terraform, inactive alternatives** (kept validated, linted and tested in CI, never applied): `envs/oci` + `modules/te-tengo-oci`, one Ampere A1 VM on OCI Always Free (dropped for lack of A1 capacity); `envs/mvp` + `modules/te-tengo` + `bootstrap/`, the same host on AWS EC2 `t4g.small`, "VM only" by default (S3, SES, SNS and Route53 optional), verified against the Floci emulator through `envs/local`.
- **API image pinned by digest:** `te_tengo_api_digest` (`sha256:…`) makes the app role run `<repository>:<tag>@<digest>`; `te_tengo_api_tag: current` keeps both the tag and the digest the host runs.
- **Database backup before an image change:** when the target API image differs from the running one, the app role runs `te-tengo-backup.service` (dump on the host and on R2) and waits for it before switching (`te_tengo_backup_before_image_change`, default `true`); a failed backup stops the deploy.
- **Release verification against the API in production:** `release.yml` runs the test host with the digest of GHCR `latest` (the image in production; `TT_API_IMAGE_REF` for `make test-image`), or te-tengo-general-api's `develop` when no production image can be read, instead of the API's `main`, which lagged behind the schema the smoke test expects.
- **Ansible roles** (`ansible/site.yml`, over plain SSH on Azure/OCI or SSH over SSM on AWS): `base` (unattended upgrades, journald cap, swap and sysctl by memory profile, the OCI image firewall on OCI only, extra authorized keys such as the deploy key), `docker` (Docker Engine, Buildx and Compose from Docker's apt repository, log rotation), `app` (validates the settings and the vault, renders the Compose stack and its env files, gets the API image from GHCR, an archive or a build, starts the stack and checks it over HTTPS; `te_tengo_api_tag: current` keeps the deployed image) and `backup`.
- **Docker Compose stack** (`compose/`): Caddy (Let's Encrypt, HSTS), `te-tengo-general-api`, PostgreSQL 18 on an internal network and MediaMTX for the live view (RTSPS on 8322 with Caddy's certificate, LL-HLS behind Caddy under `/vivo/`, authorization through the API, browser origins restricted with `te_tengo_hls_allow_origins`). Memory profiles from `tiny` (1 GiB Azure default) to `large`, measured on a 1 GiB test host and on the real VM.
- **Cloudflare R2 storage and backups:** clips, database dumps and the Terraform state in R2; daily `pg_dump` at 03:30 Lima (last 7 kept on the host, every dump copied to R2) and `te-tengo-restore` from a local file, an R2 object or `latest`. E-mail through a generic SMTP relay and push through Firebase Cloud Messaging.
- **Continuous deployment with approval** (`deploy.yml`): `repository_dispatch` `desplegar-api` from te-tengo-general-api's `produccion.yml` (after an API release reaches its `main`) or `rollback.yml`, with `{digest, tag, version, ref, kind, request}`; the run name ends with `[<request>]` so the API workflow can poll this run and tag its release only after a successful deploy. Also called by this repository's `produccion.yml` (configuration-only redeploy with the current image) and `rollback.yml`, or run by hand with a tag and/or digest. Production runs wait for a required reviewer on the `produccion` environment, then run the app role over SSH with a pinned host key and the committed, non-secret `ansible/prod.yml`, and check `/actuator/health`; a `produccion` environment without its variables or secrets fails the run.
- **CI and local tests:** `terraform.yml` (fmt, validate, `terraform test` with mocked providers, tflint, checkov) and `ansible.yml` (yamllint, ansible-lint, syntax check, `docker compose config`, deploy to a containerized Ubuntu 24.04 host with Floci as the R2 stand-in plus a smoke test); `make test-all` runs the same locally without a cloud account.
- **Documentation:** README, `docs/terraform.md` (resources, costs, runbooks), `docs/ansible.md`, `docs/deploy.md` (runbook, CD, secrets inventory, rollback) and `docs/interface-terraform-ansible.md` (the inventory contract).
