# Changelog

Format based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/); the project uses [semantic versioning](https://semver.org/).

## [Unreleased]

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
