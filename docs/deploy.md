# Deploy runbook (Terraform → Ansible → Compose)

End-to-end procedure to put the Te Tengo backend in production: one **Azure VM** (`Standard_B2ats_v2`, 2 vCPU AMD, 1 GiB, Ubuntu 24.04 x64, Azure for Students subscription, region `chilecentral`) running Caddy, the API, PostgreSQL 18 and MediaMTX with Docker Compose under the `tiny` memory profile; clips and dumps in **Cloudflare R2**; DNS at **Namify**; e-mail through an **SMTP relay**; push through Firebase. **First run on 2026-10-08** (API image loaded from an archive, `te_tengo_api_source: archive`; no SMTP relay yet, so e-mails are only logged): the playbook passed its HTTPS checks, Let's Encrypt issued the certificate in seconds and the first backup reached R2. Still pending: the SMTP relay, and the first registry deploy (GHCR image) that switches production to the continuous deployment of section 4. Infrastructure details: [terraform.md](terraform.md); host and stack details: [ansible.md](ansible.md); handoff contract: [interface-terraform-ansible.md](interface-terraform-ansible.md). The inactive alternatives (`envs/oci`, plain SSH like Azure; `envs/mvp`, SSH over SSM) are noted where they differ.

## 0. Prerequisites (operator machine)
- Terraform ≥ 1.10, the Azure CLI, Ansible core ≥ 2.18 (`make galaxy` for the collections), Docker (for the local test), `jq`, `openssl`, an OpenSSH key pair.
- `az login` done with the Azure for Students account, the R2 buckets and tokens ([terraform.md](terraform.md#runbook-first-apply-on-azure-operator), steps 1–3).
- An API image in `ghcr.io/te-tengo-tech/te-tengo-general-api` built for **linux/amd64** (te-tengo-general-api Release workflow, from its `release/*` branches; it publishes amd64 and arm64). Note its tag.
- Before touching the cloud, run the whole thing locally: `make test-all TT_API_SRC=../te-tengo-general-api` (same SSH path, R2-style storage, the `tiny` profile and the host capped at 1 GiB; see [ansible.md](ansible.md#local-test-without-a-cloud-account-test)).

## 1. Infrastructure (Terraform, envs/azure)
1. `az login`; fill `envs/azure/terraform.tfvars` (`subscription_id` from `az account show --query id -o tsv`, `location = "chilecentral"`, `ssh_public_key`, `app_hostname`, `object_storage_endpoint`) and `envs/azure/backend.hcl`; `make azure-init && make azure-plan`, review, `make azure-apply` ([terraform.md](terraform.md#runbook-first-apply-on-azure-operator), steps 4–6).
2. What must come out of it, checked before Ansible: an NSG with 80/tcp, 443/tcp+udp and 8322/tcp open to anyone and 22 from `admin_cidrs` (anywhere by default, key-only SSH); a `Standard_B2ats_v2` VM with a 30 GB Standard SSD; a static public IP (output `public_ip`); `memory_profile = tiny`.
3. DNS at Namify: A record `api.tetengo` in `reqsai.tech` → `public_ip` (output `dns_record`). Let's Encrypt needs the name to resolve **before** the first deploy. Check it on Namify's own name servers (`dig +short api.tetengo.reqsai.tech @tech-domains.earth.orderbox-dns.com`), not on a public resolver: the zone caches a missing name for 2 hours (SOA negative TTL 7200 s), so a lookup before the record exists keeps failing on that resolver for up to 2 hours. For the same reason, start the app role (Caddy) only once the record is there; `--tags base,docker,backup` can run before.
4. First SSH with host-key verification against the boot diagnostics serial log ([terraform.md](terraform.md#runbook-first-apply-on-azure-operator), step 8).

## 2. Inventory and vault
```bash
make inventory                                   # ansible/inventory/hosts.yml from envs/azure outputs (git-ignored)
cp ansible/group_vars/te_tengo/vault.yml.example ansible/group_vars/te_tengo/vault.yml
$EDITOR ansible/group_vars/te_tengo/vault.yml    # see "Secrets inventory"
ansible-vault encrypt ansible/group_vars/te_tengo/vault.yml
```
**Production settings that are not secret live in the committed [`ansible/prod.yml`](../ansible/prod.yml)**: image source (`registry`, public package, `te_tengo_api_tag: current`), `te_tengo_acme_email`, `te_tengo_push_provider`, the PWA's origins (`te_tengo_hls_allow_origins` and `TT_CORS_ORIGENES`, `TT_PWA_URL`, `TT_ENLACE_BASE` in `te_tengo_api_settings`) and the deploy key in `te_tengo_authorized_keys`. `make deploy` and `make redeploy` pass it (`DEPLOY_VARS`), and so does the Deploy workflow, so the operator and CI render the same configuration. It is an extra-vars file rather than `group_vars/te_tengo` because that group also holds the local test host and the inactive OCI and AWS hosts. Only operator-specific values go in an untracked `ansible/prod.local.yml` passed after it (`ANSIBLE_ARGS="-e @prod.local.yml"`): the operator's `ansible_ssh_private_key_file`, or `te_tengo_api_source: archive` with `te_tengo_api_archive`. Remove from an existing `prod.local.yml` the values now in `prod.yml` (ACME e-mail, push provider, origins, `te_tengo_api_settings`): being passed later, they would shadow future changes of `prod.yml`. Other settings, in `prod.yml` or `ansible/group_vars/te_tengo/vars.yml`: the SMTP relay (`te_tengo_smtp_host`, `te_tengo_smtp_port`, `te_tengo_smtp_security`, `te_tengo_smtp_sender`; only once the API release supports `smtp`, see [ansible.md](ansible.md#variables)) and `te_tengo_registry_auth: login` + `te_tengo_registry_username` if the GHCR package were private.

Check access before deploying (the key is the private half of Terraform's `ssh_public_key`; port 22 accepts `admin_cidrs`, anywhere by default):
```bash
cd ansible && ansible te_tengo -m ansible.builtin.ping --ask-vault-pass
```

## 3. First deploy (operator, full playbook)
```bash
make deploy ANSIBLE_ARGS="-e @prod.local.yml -e te_tengo_api_tag=<tag>"   # prod.yml is passed by the Makefile
```
It installs the base packages, the 2 GiB swap file of the `tiny` profile, Docker, the stack and the backup timer (on the inactive OCI alternative it also opens the stack's ports in the OCI image's iptables policy; on Azure the NSG is the only firewall and those tasks are skipped), then verifies over HTTPS from the host: health `UP` with HSTS, HLS 401 without a token, internal and Swagger endpoints 404. From your machine:
```bash
curl -fsS https://api.tetengo.reqsai.tech/actuator/health
curl -s -o /dev/null -w '%{http_code}\n' https://api.tetengo.reqsai.tech/vivo/camaras/x/index.m3u8      # 401
openssl s_client -connect api.tetengo.reqsai.tech:8322 -servername api.tetengo.reqsai.tech </dev/null | openssl x509 -noout -issuer -enddate   # Let's Encrypt
make backup-now && ssh ubuntu@<public_ip> sudo journalctl -u te-tengo-backup --no-pager -n 5          # dump uploaded to R2
```
The post-deploy check runs **on the VM against its own public name**. Azure lets the VM reach its own public IP (hairpin), so the check works (verified on the first deploy). If it ever times out while the commands above work from outside, deploy with `-e app_verify=false` and report it.

On the 1 GiB host the first start is slow (image pulls, Flyway, the JVM with C1 only); the playbook waits up to 15 minutes (`app_compose_wait_timeout`). Check memory after the first day: `ssh ubuntu@<public_ip> 'free -m; sudo docker stats --no-stream'`; the local measurement is in [ansible.md](ansible.md#memory-profiles).

Then seed the first household installation (`scripts/create-installation.sh` of the API, run against the host's PostgreSQL: `docker compose exec -T postgres psql -U tetengo -d tetengo` in `/opt/te-tengo`).

## 4. Release flow and continuous deployment (GitHub Actions)
Every repository of Te Tengo follows the same git flow strategy, "build once, deploy many": environments are promoted from the **release branch**, and `main` and the tag come **last**, after production was approved. **Nothing is deployed on a push to `main`.** Two pipelines reach the production VM, both through [`deploy.yml`](../.github/workflows/deploy.yml) and its `produccion` approval:

```mermaid
flowchart TD
  subgraph api["te-tengo-general-api: push to release/x.y.z or hotfix/x.y.z (its release.yml)"]
    abuild["build: image once (amd64 + arm64)<br/>GHCR sha-&lt;short&gt; + x.y.z-rc, digest"] --> astaging["staging (environment staging):<br/>ephemeral stack in the runner, same digest<br/>smoke test + end-to-end"]
    astaging --> aprod["produccion: repository_dispatch desplegar-api<br/>{tag, digest, ref, version}"]
    aprod --> apr["pull request release/x.y.z → main"]
  end
  subgraph infra["te-tengo-infra: push to release/x.y.z or hotfix/x.y.z (release.yml)"]
    icheck["check: VERSION, yamllint, ansible-lint,<br/>syntax check, compose config"] --> istaging["staging (environment staging):<br/>containerized host, make test-all<br/>on the release commit"]
    istaging --> iprod["produccion: calls deploy.yml<br/>api_tag empty = current (configuration only)"]
    iprod --> ipr["pull request release/x.y.z → main"]
  end
  aprod --> deploy["deploy.yml (from main for the dispatch)<br/>plan: tag must still resolve to the digest<br/>deploy-ssh in environment produccion: WAITS for approval<br/>Ansible app role over SSH, prod.yml<br/>GET /actuator/health = UP"]
  iprod --> deploy
  apr -->|"human merge"| amain["main: etiquetar.yml<br/>tag vX.Y.Z, GitHub Release,<br/>image tags x.y.z + latest, back-merge PR"]
  ipr -->|"human merge"| imain["main: etiquetar.yml<br/>tag vX.Y.Z (VERSION), GitHub Release,<br/>back-merge PR main → develop"]
```

### Deploy (`deploy.yml`)
| Trigger | Target | Image tag |
|---|---|---|
| `repository_dispatch` `desplegar-api` (the `produccion` stage of te-tengo-general-api's Release workflow, after its staging) | `azure` (`produccion`) | `client_payload.tag`, e.g. `sha-1a2b3c4`. `client_payload.digest` is checked against the registry before the deploy (the tag must still point to the staged image); `ref` (the API commit) and `version` are shown in the run summary |
| `workflow_call` from this repository's Release workflow (`produccion` stage of an infra release) | `azure` (`produccion`) | `current`: configuration only, the image the host already runs |
| Manual (*Actions → Deploy → Run workflow*, from `main` or a release branch) | `azure` (default), `oci` or `aws` | the `api_tag` input; empty = `current`. Optional check mode (`--check --diff`) |

```
plan (no environment, no secrets): target azure, tag from the payload or the inputs, validated; with a digest,
  `docker buildx imagetools inspect ghcr.io/te-tengo-tech/te-tengo-general-api:<tag>` must return that digest
  └─ deploy-ssh, environment "produccion" ─► WAITS for a required reviewer (jhosepmyr, elmer-riva)
       ─► SSH with the deploy key, pinned host key ─► ansible-playbook site.yml --tags app -e @prod.yml
          (te_tengo_api_source=registry, te_tengo_registry_auth=none, te_tengo_api_tag=<tag or current>)
       ─► the role's own HTTPS checks on the VM ─► GET https://api.tetengo.reqsai.tech/actuator/health = UP
```

- **Switch.** Every deploy job runs only when the organization variable **`ENABLE_API_DEPLOY`** is `true` (table below); otherwise it is skipped and the `plan` job's summary says why.
- **Approval.** The `deploy-ssh` job runs in the GitHub environment **`produccion`** (required reviewers; branch policy `release/*`, `hotfix/*` and `main`), so every production run pauses until a reviewer approves under *Actions → the run → Review deployments*; nothing touches the VM before that. The small `plan` job before it has no environment and no secrets. A manual run from any other branch is refused by the branch policy.
- **Not configured yet = a notice.** The environment's variables and secrets are checked as the first step after the approval: if any is missing the job ends green with a notice listing them, without touching the VM.
- **Digest check.** The registry is read anonymously, so the check needs the public GHCR package; while the package is private it only warns and the deploy goes on with the tag.
- **`te_tengo_api_tag: current`.** A configuration deploy keeps the image: the app role reads `API_IMAGE` from the host's `/opt/te-tengo/.env` (written by the previous deploy) and reuses its tag (`ansible/roles/app/tasks/current-tag.yml`). If the host does not run a GHCR image (today it runs `te-tengo-general-api:local`, loaded from an archive) or was never deployed, the run fails before changing anything and asks for a tag. So **the first CI deploy must name a tag** (an API release, or a manual run with `api_tag`); from then on `current` works, with no repository variable to keep in sync. An infra release before that first API release fails in its `produccion` stage for this reason.
- **One deploy at a time.** The job's concurrency group `deploy-produccion` never cancels a running deploy. GitHub keeps at most one *pending* run per group: a third run cancels the one still waiting (not the running one), so if an API release and an infra release land at the same moment, check that the API tag was deployed and re-run it by hand otherwise.
- **Workflow on `main`.** `repository_dispatch` only starts the workflow file of the default branch, on that branch, so changes to `deploy.yml` reach API releases once they are on `main`. The `workflow_call` of an infra release uses the release branch's own `deploy.yml`.
- **Public image.** The VM pulls without credentials (`te_tengo_registry_auth: none`): the GHCR package must be made public once (te-tengo-general-api `docs/DEPLOYMENT.md`, *One-time steps*). A linked package inherits the repository's access permissions, not its visibility.
- **Port 22.** The NSG accepts SSH from anywhere by default, so the GitHub-hosted runner reaches the VM directly; authentication is key-only and the VM's host key is **pinned** (`StrictHostKeyChecking=yes` with `SSH_KNOWN_HOSTS`), so a replaced or impersonated host stops the deploy.

### Release pipeline of this repository (`release.yml`)
A push to `release/x.y.z` or `hotfix/x.y.z` of te-tengo-infra:

| Job | Environment | What it does |
|---|---|---|
| `check` | none | Reads `VERSION` (a warning if the branch name differs) and runs the static checks of `ansible.yml` on the release commit: yamllint, ansible-lint (production profile), the playbook syntax check with `prod.yml`, `docker compose config`. Its summary lists the switches |
| `staging` | `staging` (required reviewers) | The local container harness, as `make test-all`: `make test-host-up`, `test-deploy` (the whole `site.yml` against the containerized Ubuntu 24.04 host capped at 1 GiB, API image built from te-tengo-general-api's `main`), `test-smoke` (through Caddy over HTTPS, clips on Floci as R2, backup and restore) and `test-memory` (the `tiny` budget), then `test-down` |
| `produccion` | `produccion`, inside `deploy.yml` | Calls `deploy.yml` with target `azure` and an empty tag: a configuration-only redeploy of the app role with the image the host already runs, after an approval. Needs `staging`, or only `check` when `ENABLE_STAGING` is off |
| `pull-request` | none | Opens the pull request `release/x.y.z → main` (title `release: x.y.z`) with `GITHUB_TOKEN`, listing what ran where, or updates its description when it is already open. Merging it is a human action (the `main` ruleset needs a review) |

On `main`, [`etiquetar.yml`](../.github/workflows/etiquetar.yml) creates the tag `vX.Y.Z` from `VERSION` and a GitHub Release with the `CHANGELOG.md` section of that version as notes (skipped if the tag exists), then opens the back-merge pull request `main → develop` (`chore: merge release x.y.z back into develop`).

- **Preparing a release.** Branch `release/x.y.z` from `develop`, set `VERSION` to `x.y.z` and rename `[Unreleased]` in `CHANGELOG.md` to `[x.y.z] - <date>`, push. Hotfixes branch from `main` as `hotfix/x.y.z`.
- **Re-running.** A new push to the same release branch runs the pipeline again. Runs of one branch never overlap (concurrency group per branch) and a running one is never cancelled, since it may be deploying; a newer push waits and replaces an older run that has not started yet. A run still waiting for an approval can be rejected on its run page.
- **API access for staging.** te-tengo-general-api is public, so the workflow's own token checks it out; the `API_REPO_TOKEN` secret is only needed if it becomes private (`ansible.yml` still skips its deploy test without that secret).

### Switches
Each stage has an on/off switch: an **organization** Actions variable of `Te-Tengo-Tech` (*Settings → Secrets and variables → Actions → Variables*), the single control panel for every repository. They are explicit opt-in: only the value `true` turns a channel on, and an unset variable means off. With the switch on, a production deploy still waits for an approval on `produccion`.

| Variable | What it controls | Suggested value |
|---|---|---|
| `ENABLE_STAGING` | The `staging` job of `release.yml` (the containerized host). Off: `produccion` only needs the `check` job | `true` |
| `ENABLE_API_DEPLOY` | The `produccion` job of `release.yml` and the `deploy-ssh` and `deploy-aws` jobs of `deploy.yml`, for every trigger (`desplegar-api` dispatch, infra release, manual) and target. Anything but `true` freezes production: the job shows as skipped and the summary says why. `te-tengo-general-api` gates its `desplegar-api` dispatch with the same variable | `true` |

### One-time setup of the `produccion` environment (te-tengo-infra)
1. **Deploy key.** A dedicated ed25519 pair without passphrase, only for GitHub Actions: `ssh-keygen -t ed25519 -N '' -C te-tengo-deploy -f ~/.ssh/te_tengo_deploy_ed25519` (already generated on the operator's Mac; its public half is in `ansible/prod.yml` as `no-agent-forwarding,no-port-forwarding,no-X11-forwarding ssh-ed25519 AAAA... te-tengo-deploy`: no agent, port or X11 forwarding; no `from=` because GitHub-hosted runners have no fixed address; not `restrict`, which would also forbid a PTY and was not tested with Ansible's SSH options). The key logs in as `ubuntu`, which has sudo: it is as powerful as the operator's key, so keep it only in the GitHub secret and the operator's `~/.ssh`.
2. **Install its public half on the VM** (operator, with the operator's own key): `make deploy ANSIBLE_ARGS="-e @prod.local.yml --tags authorized_keys"`, then check `ssh -i ~/.ssh/te_tengo_deploy_ed25519 -o IdentitiesOnly=yes ubuntu@57.156.59.215 true`.
3. **Environment variables and secrets** (*Settings → Environments → produccion*, or `gh` as below, from the te-tengo-infra checkout that holds the vault):

| Kind | Name | Value and how to produce it |
|---|---|---|
| secret | `ANSIBLE_VAULT_B64` | the **encrypted** vault, base64: `base64 < ansible/group_vars/te_tengo/vault.yml \| gh secret set ANSIBLE_VAULT_B64 --env produccion -R Te-Tengo-Tech/te-tengo-infra` (check `head -1` of the file is `$ANSIBLE_VAULT;1.1;AES256` first) |
| secret | `ANSIBLE_VAULT_PASSWORD` | the vault password (password manager): `gh secret set ANSIBLE_VAULT_PASSWORD --env produccion -R Te-Tengo-Tech/te-tengo-infra` (prompts) |
| secret | `DEPLOY_SSH_PRIVATE_KEY` | private half of the deploy key: `gh secret set DEPLOY_SSH_PRIVATE_KEY --env produccion -R Te-Tengo-Tech/te-tengo-infra < ~/.ssh/te_tengo_deploy_ed25519` |
| variable | `SSH_KNOWN_HOSTS` | the VM's ed25519 host key line `57.156.59.215 ssh-ed25519 AAAA...`: `ssh-keyscan -t ed25519 57.156.59.215 2>/dev/null`, **after** checking that `ssh-keyscan -t ed25519 57.156.59.215 2>/dev/null \| ssh-keygen -lf -` prints the fingerprint the operator already trusts (`ssh-keygen -l -F 57.156.59.215`, or the boot diagnostics log of [terraform.md](terraform.md#runbook-first-apply-on-azure-operator), step 8); then `gh variable set SSH_KNOWN_HOSTS --env produccion -R Te-Tengo-Tech/te-tengo-infra --body "<that line>"` |
| variable | `ANSIBLE_INVENTORY` | the Terraform inventory (no secrets in it): `terraform -chdir=envs/azure output -raw ansible_inventory`, the same as the operator's `ansible/inventory/hosts.yml`: `gh variable set ANSIBLE_INVENTORY --env produccion -R Te-Tengo-Tech/te-tengo-infra < ansible/inventory/hosts.yml` |
| variable | `APP_URL` | `https://api.tetengo.reqsai.tech` (Terraform output `app_url`); the health check calls `$APP_URL/actuator/health` |
| variable | `DEPLOY_RUNNER` | optional: label of a self-hosted runner (only with a narrowed `admin_cidrs`); default `ubuntu-24.04` |

   Rotate `ANSIBLE_VAULT_B64` every time the vault changes. The old `prod` environment is no longer used by the workflow and can be deleted.
4. **te-tengo-general-api:** the `DISPATCH_TOKEN` secret and the public GHCR package (its `docs/DEPLOYMENT.md`).
5. **First registry deploy:** when the first API release reaches its `produccion` stage, approve the dispatched run here, or run **Deploy** by hand with `api_tag = sha-<short commit>` of an image the API's Release workflow pushed. Until then `current` has no registry image to keep.

**If `admin_cidrs` is narrowed** (and always on the OCI alternative, whose `admin_cidrs` has no default), GitHub-hosted runners, which have no fixed address, can no longer reach port 22. Options, cheapest first:
1. Run the workflow on a **self-hosted runner** whose public IP is in `admin_cidrs` (the operator's machine or another always-on box): register it, set `DEPLOY_RUNNER` to its label. It needs `pipx`, `curl` and `jq`.
2. Deploy from the operator's machine with `make redeploy ANSIBLE_ARGS="-e @prod.local.yml -e te_tengo_api_tag=<tag>"` (same playbook, same result).
3. Add the runner's address to `admin_cidrs` for the deploy and remove it afterwards (`terraform apply` from the operator's machine).
A temporary NSG rule managed from the workflow (Azure credentials through GitHub OIDC) or Azure Bastion would also work; neither is implemented (Bastion is a paid resource).

**Target `oci`, GitHub environment `oci` (inactive):** manual runs only; the same SSH job with the variables and secrets above in the `oci` environment, `ANSIBLE_INVENTORY` from `envs/oci`, and **without** `prod.yml` (production settings of the Azure host). Protect it with required reviewers if it is ever used.

**Target `aws`, GitHub environment `mvp` (inactive):** manual runs only; OIDC → the Terraform deploy role → SSH over SSM. Variables `AWS_DEPLOY_ROLE_ARN` (output `github_deploy_role_arn`), `AWS_REGION`, `EC2_INSTANCE_ID` (output `instance_id`), `APP_URL`, `ANSIBLE_INVENTORY` (from `envs/mvp`); the same three secrets, with the deploy key restricted to the SSM tunnel (`from="127.0.0.1,::1",...`). The session name `te-tengo-mvp-deploy-<run id>` is required by the role's policy.

## 5. Operations
- Shell and logs: `ssh ubuntu@<public_ip>`, then `cd /opt/te-tengo && sudo docker compose logs -f api`.
- Restart one service: `sudo docker compose restart api`. Configuration changes go through Ansible (`make redeploy`), never by editing `/opt/te-tengo` by hand.
- Backups: daily at 03:30 Lima (`systemctl list-timers te-tengo-backup.timer`); on demand `make backup-now`; last 7 dumps in `/var/backups/te-tengo`, every dump in `s3://te-tengo-backups/postgres/` on R2 (expiry: the R2 lifecycle rule, if you created it).
- Restore: `sudo te-tengo-restore /var/backups/te-tengo/te-tengo-<stamp>.dump` or `sudo te-tengo-restore latest` (newest dump in R2; the backups token can read). It stops the API, recreates the database, restores and starts the API. Test a restore after the first week.
- Credit watch: the remaining Azure for Students credit and its use per service on the [Azure Sponsorships balance page](https://www.microsoftazuresponsorships.com/balance) after the first week and every month (the VM hours should not appear; the IP and the disk do; [terraform.md](terraform.md#cost-what-the-credit-pays)); R2 usage in the Cloudflare dashboard (10 GB-month free).
- Memory: `free -m` and `sudo docker stats --no-stream` on the host; `swapon --show` shows the 2 GiB swap file. If the API restarts with `OutOfMemoryError` or the host swaps constantly, resize to `Standard_B2als_v2` ([terraform.md](terraform.md#runbook-first-apply-on-azure-operator), *Resize*).

## 6. Rollback
| What broke | Rollback |
|---|---|
| A new API image | Run **Deploy** by hand with the previous `sha-<short commit>` tag (each run's summary names its tag; or `make redeploy ANSIBLE_ARGS="-e @prod.local.yml -e te_tengo_api_tag=<previous tag>"`). A later configuration deploy keeps that tag (`current`) until the next API release. Flyway migrations are forward-only: if the bad release migrated the schema, restore the dump taken before it (the deploy does not take one: run `make backup-now` before any release with a migration). |
| Configuration (Caddyfile, mediamtx.yml, env) | Revert the commit in this repository and redeploy the app role; handlers reload Caddy and restart MediaMTX/API. |
| Data | `te-tengo-restore` with the latest good dump (see above). |
| The host | Terraform recreates the VM (`terraform -chdir=envs/azure apply -replace=module.te_tengo.azurerm_linux_virtual_machine.app`; the static IP stays, so the A record at Namify stays valid), refresh `SSH_KNOWN_HOSTS` (new host key), `make inventory && make deploy` and restore the last dump from R2 (`te-tengo-restore latest`). Caddy gets a new certificate (Let's Encrypt rate limits: 5 duplicate certificates per week). |
| Certificate | Caddy renews by itself; if RTSPS still serves an old certificate, `sudo docker compose restart mediamtx`. |

## Secrets inventory
| Secret | Where it lives | On the host | Rotation |
|---|---|---|---|
| PostgreSQL password (`vault_postgres_password`) | Ansible Vault | `.env`, `api.env` (0600 root) | Change in the vault, `ALTER USER tetengo PASSWORD …` in the container, redeploy |
| JWT RS256 key pair (`vault_jwt_private_key_pem`, `vault_jwt_public_key_pem`) | Ansible Vault | `secrets/jwt-*.pem` (0600, UID 10001) | Replace both and redeploy: every session and agent token becomes invalid (apps sign in again, agents re-register by themselves) |
| MediaMTX hook secret (`vault_mediamtx_auth_secret`) | Ansible Vault | `.env` and `api.env` | Replace and redeploy (MediaMTX and the API restart together) |
| Firebase service-account key (`vault_fcm_credentials_json`) | Ansible Vault (never in git, never in `~/.config` copies) | `secrets/fcm.json` (0600, UID 10001) | New key in the Firebase console, update the vault, redeploy, delete the old key |
| R2 clips token (`vault_clips_s3_access_key_id`, `vault_clips_s3_secret_access_key`) | Ansible Vault | `api.env` (0600 root) | New token in the Cloudflare dashboard (Object Read & Write, clips bucket), update the vault, `make redeploy`, revoke the old one. Pre-signed URLs already issued stop working |
| R2 backups token (`vault_backup_s3_access_key_id`, `vault_backup_s3_secret_access_key`) | Ansible Vault | `/etc/te-tengo/backup.env` (0600 root) | New token (backups bucket), update the vault, `make deploy ANSIBLE_ARGS="--tags backup"`, revoke the old one |
| R2 state token | Operator's `~/.aws/credentials` (`[r2-tfstate]`) | — | New token (tfstate bucket), update the profile, revoke the old one |
| SMTP credentials (`vault_smtp_username`, `vault_smtp_password`) | Ansible Vault | `api.env` | New password or API key at the relay, update the vault, `make redeploy` |
| GHCR token (`vault_registry_password`) | Ansible Vault | Docker credential store of root | Only if the package is private |
| Vault password | Password manager; GitHub secret `ANSIBLE_VAULT_PASSWORD` (environment `produccion`) | — | `ansible-vault rekey`, update the secret and `ANSIBLE_VAULT_B64` |
| Deploy SSH key | GitHub secret `DEPLOY_SSH_PRIVATE_KEY` (environment `produccion`) and the operator's `~/.ssh/te_tengo_deploy_ed25519`; public half in `te_tengo_authorized_keys` of `ansible/prod.yml` | `~ubuntu/.ssh/authorized_keys` | New pair, replace the public half in `prod.yml`, `make deploy ANSIBLE_ARGS="-e @prod.local.yml --tags authorized_keys"`, update the secret, remove the old line from `authorized_keys` by hand (the role only adds keys) |
| Operator SSH key | Operator's machine; public half in Terraform's `ssh_public_key` (VM `admin_ssh_key`) | `~ubuntu/.ssh/authorized_keys` | Add the new key with `te_tengo_authorized_keys`, then remove the old line by hand |
| Azure CLI login | Operator's `~/.azure` (token cache of `az login`) | — | `az logout` / `az login`; nothing Azure-related is stored in GitHub |
| OCI API signing key (inactive alternative) | Operator's `~/.oci/config` | — | Add a new key in the console, update the config, delete the old key |
| Cloud credentials on the host | **None**: no Azure, OCI or AWS credentials (no managed identity; AWS alternative: instance role through IMDSv2, GitHub uses OIDC) | — | — |
| TLS private key | Generated by Caddy | `caddy-data` volume (MediaMTX reads it read-only) | Automatic with renewal |
