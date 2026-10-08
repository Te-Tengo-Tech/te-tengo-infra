# Deploy runbook (Terraform → Ansible → Compose)

End-to-end procedure to put the Te Tengo backend in production: one **OCI Ampere A1 VM** (Always Free, arm64, Ubuntu 24.04, 1 OCPU / 6 GB) running Caddy, the API, PostgreSQL 18 and MediaMTX with Docker Compose; clips and dumps in **Cloudflare R2**; DNS at **Namify**; e-mail through an **SMTP relay**; push through Firebase. **Not run yet**: it needs the OCI account, the R2 buckets and tokens, the DNS record, the Firebase key, the SMTP relay and a published API image. Infrastructure details: [terraform.md](terraform.md); host and stack details: [ansible.md](ansible.md); handoff contract: [interface-terraform-ansible.md](interface-terraform-ansible.md). The AWS alternative (`envs/mvp`, SSH over SSM) is inactive; its differences are noted where they matter.

## 0. Prerequisites (operator machine)
- Terraform ≥ 1.10, Ansible core ≥ 2.18 (`make galaxy` for the collections), Docker (for the local test), `jq`, `openssl`, an OpenSSH key pair.
- An OCI API signing key in `~/.oci/config`, the R2 buckets and tokens ([terraform.md](terraform.md#runbook-first-apply-on-oci-operator), steps 1–3).
- An API image in `ghcr.io/te-tengo-tech/te-tengo-general-api` built for **linux/arm64** (te-tengo-general-api release workflow). Note its tag.
- Before touching the cloud, run the whole thing locally: `make test-all TT_API_SRC=../te-tengo-general-api` (same SSH path and R2-style storage; see [ansible.md](ansible.md#local-test-without-a-cloud-account-test)).

## 1. Infrastructure (Terraform, envs/oci)
1. Fill `envs/oci/terraform.tfvars` and `envs/oci/backend.hcl`; `make oci-init && make oci-plan`, review, `make oci-apply` ([terraform.md](terraform.md#runbook-first-apply-on-oci-operator), steps 4–6).
2. What must come out of it, checked before Ansible: security list with 80/tcp, 443/tcp+udp and 8322/tcp open to anyone and **22 only from `admin_cidrs`**; the default security list emptied; the A1 instance with 1 OCPU / 6 GB and a 50 GB boot volume; a public IP (output `public_ip`).
3. DNS at Namify: A record `api.tetengo` in `reqsai.tech` → `public_ip` (output `dns_record`). Let's Encrypt needs the name to resolve **before** the first deploy (`dig +short api.tetengo.reqsai.tech`).
4. First SSH with host-key verification ([terraform.md](terraform.md#runbook-first-apply-on-oci-operator), step 8).

## 2. Inventory and vault
```bash
make inventory                                   # ansible/inventory/hosts.yml from envs/oci outputs (git-ignored)
cp ansible/group_vars/te_tengo/vault.yml.example ansible/group_vars/te_tengo/vault.yml
$EDITOR ansible/group_vars/te_tengo/vault.yml    # see "Secrets inventory"
ansible-vault encrypt ansible/group_vars/te_tengo/vault.yml
```
Set in `ansible/group_vars/te_tengo/vars.yml` (or an untracked `ansible/*.local.yml` passed with `-e @`): `te_tengo_acme_email`, `te_tengo_api_tag`, the SMTP relay (`te_tengo_smtp_host`, `te_tengo_smtp_port`, `te_tengo_smtp_security`, `te_tengo_smtp_sender`; only once the API release supports `smtp`, see [ansible.md](ansible.md#variables)), and `te_tengo_registry_auth: login` + `te_tengo_registry_username` if the GHCR package is private.

Check access before deploying (from an address in `admin_cidrs`; the key is the private half of Terraform's `ssh_public_key`):
```bash
cd ansible && ansible te_tengo -m ansible.builtin.ping --ask-vault-pass
```

## 3. First deploy (operator, full playbook)
```bash
make deploy ANSIBLE_ARGS="-e te_tengo_api_tag=<tag>"
```
It installs the base packages, swap, opens the stack's ports in the OCI image's iptables policy, Docker, the stack and the backup timer, then verifies over HTTPS from the host: health `UP` with HSTS, HLS 401 without a token, internal and Swagger endpoints 404. From your machine:
```bash
curl -fsS https://api.tetengo.reqsai.tech/actuator/health
curl -s -o /dev/null -w '%{http_code}\n' https://api.tetengo.reqsai.tech/vivo/camaras/x/index.m3u8      # 401
openssl s_client -connect api.tetengo.reqsai.tech:8322 -servername api.tetengo.reqsai.tech </dev/null | openssl x509 -noout -issuer -enddate   # Let's Encrypt
make backup-now && ssh ubuntu@<public_ip> sudo journalctl -u te-tengo-backup --no-pager -n 5          # dump uploaded to R2
```
The post-deploy check runs **on the VM against its own public name**. Whether OCI routes a VM's connection to its own public IP back through the internet gateway was not verified (no account yet). If that check times out while the commands above work from outside, deploy with `-e app_verify=false` and report it.

Then seed the first household installation (`scripts/create-installation.sh` of the API, run against the host's PostgreSQL: `docker compose exec -T postgres psql -U tetengo -d tetengo` in `/opt/te-tengo`).

## 4. Continuous deploys (GitHub Actions, `deploy.yml`)
Manual workflow **Deploy** (`workflow_dispatch`; inputs `target` = `oci` (default) or `aws`, `api_tag`, optional check mode) → `ansible-playbook site.yml --tags app` → public health check. No Terraform runs in it. It is inert (a notice, no job) until the chosen GitHub environment is configured.

**Target `oci`, GitHub environment `prod`:** plain SSH with a dedicated key; the VM's host key is **pinned** (`StrictHostKeyChecking=yes` with the known-hosts line below), so a replaced or impersonated host stops the deploy.

| Kind | Name | Value |
|---|---|---|
| variable | `APP_URL` | Terraform output `app_url` (`https://api.tetengo.reqsai.tech`) |
| variable | `ANSIBLE_INVENTORY` | `terraform -chdir=envs/oci output -raw ansible_inventory` (no secrets in it) |
| variable | `OCI_SSH_KNOWN_HOSTS` | `ssh-keyscan -t ed25519 <public_ip>` **after** verifying the fingerprint (terraform.md, step 8), e.g. `192.0.2.10 ssh-ed25519 AAAA...` |
| variable | `DEPLOY_RUNNER` | optional: label of a self-hosted runner (see below); default `ubuntu-24.04` |
| secret | `ANSIBLE_VAULT_B64` | `base64 < ansible/group_vars/te_tengo/vault.yml` (the encrypted file) |
| secret | `ANSIBLE_VAULT_PASSWORD` | the vault password |
| secret | `DEPLOY_SSH_PRIVATE_KEY` | private half of a dedicated ed25519 key; its public half goes to `te_tengo_authorized_keys` as `no-agent-forwarding,no-port-forwarding,no-X11-forwarding ssh-ed25519 AAAA... te-tengo-deploy` and one operator run of `make deploy` (`--tags base` is enough) |

**Reaching port 22 from the runner.** The security list only lets `admin_cidrs` reach SSH, and GitHub-hosted runners have no fixed address. Options, cheapest first:
1. Run the workflow on a **self-hosted runner** whose public IP is in `admin_cidrs` (the operator's machine or another always-on box): register it, set `DEPLOY_RUNNER` to its label. It needs `pipx`, `curl` and `jq`.
2. Deploy from the operator's machine with `make redeploy ANSIBLE_ARGS="-e te_tengo_api_tag=<tag>"` (same playbook, same result) and use the workflow only once 1 is in place.
3. Add the runner's address to `admin_cidrs` for the deploy and remove it afterwards (`terraform apply` from the operator's machine). Opening 22 to `0.0.0.0/0` is **not** recommended, even with key-only SSH.
A temporary security-list rule managed from the workflow (OCI CLI with an API key stored in GitHub) or the OCI Bastion service would also work, but each needs OCI credentials in GitHub; not implemented.

Protect the environment with required reviewers.

**Target `aws`, GitHub environment `mvp` (inactive):** OIDC → the Terraform deploy role → SSH over SSM. Variables `AWS_DEPLOY_ROLE_ARN` (output `github_deploy_role_arn`), `AWS_REGION`, `EC2_INSTANCE_ID` (output `instance_id`), `APP_URL`, `ANSIBLE_INVENTORY` (from `envs/mvp`); the same three secrets, with the deploy key restricted to the SSM tunnel (`from="127.0.0.1,::1",...`). The session name `te-tengo-mvp-deploy-<run id>` is required by the role's policy.

## 5. Operations
- Shell and logs: `ssh ubuntu@<public_ip>` (from `admin_cidrs`), then `cd /opt/te-tengo && sudo docker compose logs -f api`.
- Restart one service: `sudo docker compose restart api`. Configuration changes go through Ansible (`make redeploy`), never by editing `/opt/te-tengo` by hand.
- Backups: daily at 03:30 Lima (`systemctl list-timers te-tengo-backup.timer`); on demand `make backup-now`; last 7 dumps in `/var/backups/te-tengo`, every dump in `s3://te-tengo-backups/postgres/` on R2 (expiry: the R2 lifecycle rule, if you created it).
- Restore: `sudo te-tengo-restore /var/backups/te-tengo/te-tengo-<stamp>.dump` or `sudo te-tengo-restore latest` (newest dump in R2; the backups token can read). It stops the API, recreates the database, restores and starts the API. Test a restore after the first week.
- Free-tier watch: the VM's memory metric during the first week (idle reclamation, [terraform.md](terraform.md#cost-what-is-free-and-why)), R2 usage in the Cloudflare dashboard (10 GB-month free).

## 6. Rollback
| What broke | Rollback |
|---|---|
| A new API image | Re-run **Deploy MVP** (or `make redeploy ANSIBLE_ARGS="-e te_tengo_api_tag=<previous tag>"`) with the previous tag. Flyway migrations are forward-only: if the bad release migrated the schema, restore the dump taken before it (the deploy does not take one: run `make backup-now` before any release with a migration). |
| Configuration (Caddyfile, mediamtx.yml, env) | Revert the commit in this repository and redeploy the app role; handlers reload Caddy and restart MediaMTX/API. |
| Data | `te-tengo-restore` with the latest good dump (see above). |
| The host | Terraform recreates the instance (`terraform -chdir=envs/oci apply -replace=module.te_tengo.oci_core_instance.app`), then update the A record at Namify if the ephemeral IP changed, refresh `OCI_SSH_KNOWN_HOSTS` (new host key), `make inventory && make deploy` and restore the last dump from R2 (`te-tengo-restore latest`). Caddy gets a new certificate (Let's Encrypt rate limits: 5 duplicate certificates per week). |
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
| Vault password | Password manager; GitHub secret `ANSIBLE_VAULT_PASSWORD` | — | `ansible-vault rekey`, update the secret |
| Deploy SSH key | GitHub secret `DEPLOY_SSH_PRIVATE_KEY`; public half in `te_tengo_authorized_keys` | `~ubuntu/.ssh/authorized_keys` | New pair, run the base role, update the secret, remove the old key |
| Operator SSH key | Operator's machine; public half in Terraform's `ssh_public_key` (instance metadata) | `~ubuntu/.ssh/authorized_keys` | Add the new key with `te_tengo_authorized_keys`, then remove the old line by hand |
| OCI API signing key | Operator's `~/.oci/config` | — | Add a new key in the console, update the config, delete the old key |
| Cloud credentials on the host | **None**: no OCI or AWS credentials (AWS alternative: instance role through IMDSv2; GitHub uses OIDC) | — | — |
| TLS private key | Generated by Caddy | `caddy-data` volume (MediaMTX reads it read-only) | Automatic with renewal |
