# Deploy runbook (Terraform → Ansible → Compose)

End-to-end procedure to put the Te Tengo MVP backend on AWS: one EC2 instance (t4g, arm64, Ubuntu 24.04) running Caddy, the API, PostgreSQL 18 and MediaMTX with Docker Compose. **Not run yet**: it needs the team's AWS account, a domain or the sslip.io fallback, the Firebase key and a published API image. Terraform details: `docs/terraform.md`; host and stack details: [ansible.md](ansible.md); handoff contract: [interface-terraform-ansible.md](interface-terraform-ansible.md).

## 0. Prerequisites (operator machine)
- Terraform, AWS CLI v2 with the **Session Manager plugin**, Ansible core ≥ 2.18 (`make galaxy` for the collections), Docker (for the local test), `jq`, `openssl`.
- AWS credentials of an administrator for the first apply (later, the GitHub deploy role).
- An API image in `ghcr.io/te-tengo-tech/te-tengo-general-api` built for **linux/arm64** (te-tengo-general-api release workflow). Note its tag.
- Before touching AWS, run the whole thing locally: `make test-all TT_API_SRC=../te-tengo-general-api` (see [ansible.md](ansible.md#local-test-without-aws-test)).

## 1. Infrastructure (Terraform)
1. `bootstrap/`: state bucket and lock (once per account).
2. `envs/mvp`: fill `terraform.tfvars` (region, instance type → `memory_profile`, domain or sslip.io, SES sender, `live_view_publish_port = 8322`), `make mvp-init`, `make mvp-plan`, review, apply.
3. What must come out of it, checked before Ansible: security group with 80/tcp, 443/tcp+udp and 8322/tcp open, **no 22**; IMDSv2 with hop limit 2 (the API container signs S3 URLs and calls SES with the instance role); the clips and backups buckets; the instance profile; the SES identity.
4. SES: confirm the verification e-mail or DNS records of the sender, and request production access (out of the sandbox) before real users sign up; until then only verified recipients get e-mail.
5. DNS: with a Route 53 zone Terraform creates the record; otherwise the host name is `<ip-with-dashes>.sslip.io`. Let's Encrypt needs the name to resolve to the Elastic IP **before** the first deploy.

## 2. Inventory and vault
```bash
make inventory                                   # ansible/inventory/hosts.yml from envs/mvp outputs (git-ignored)
cp ansible/group_vars/te_tengo/vault.yml.example ansible/group_vars/te_tengo/vault.yml
$EDITOR ansible/group_vars/te_tengo/vault.yml    # see "Secrets inventory"
ansible-vault encrypt ansible/group_vars/te_tengo/vault.yml
```
Set in `ansible/group_vars/te_tengo/vars.yml` (or an untracked `ansible/*.local.yml` passed with `-e @`): `te_tengo_acme_email`, `te_tengo_api_tag`, and `te_tengo_registry_auth: login` + `te_tengo_registry_username` if the GHCR package is private.

Check access through SSM before deploying:
```bash
cd ansible && ansible te_tengo -m ansible.builtin.ping --ask-vault-pass
```
(SSH over SSM needs a key for `ubuntu`: the key pair Terraform attaches from its `ssh_public_key` variable, or an `ssh-ed25519` key in `te_tengo_authorized_keys`.)

## 3. First deploy (operator, full playbook)
```bash
make deploy ANSIBLE_ARGS="-e te_tengo_api_tag=<tag>"
```
It installs the base packages, swap, Docker, the stack and the backup timer, then verifies over HTTPS from the host: health `UP` with HSTS, HLS 401 without a token, internal and Swagger endpoints 404. From your machine:
```bash
curl -fsS https://<host>/actuator/health
curl -s -o /dev/null -w '%{http_code}\n' https://<host>/vivo/camaras/x/index.m3u8      # 401
openssl s_client -connect <host>:8322 -servername <host> </dev/null | openssl x509 -noout -issuer -enddate   # Let's Encrypt
```
Then seed the first household installation (`scripts/create-installation.sh` of the API, run against the host's PostgreSQL: `docker compose exec -T postgres psql -U tetengo -d tetengo` in `/opt/te-tengo`).

## 4. Continuous deploys (GitHub Actions, `deploy.yml`)
Manual workflow **Deploy MVP** (`workflow_dispatch`, input `api_tag`, optional check mode): OIDC → the Terraform deploy role → SSH over SSM → `ansible-playbook site.yml --tags app` → public health check. It is inert (a notice, no job) until the GitHub environment **`mvp`** has:

| Kind | Name | Value |
|---|---|---|
| variable | `AWS_DEPLOY_ROLE_ARN` | Terraform output `github_deploy_role_arn` |
| variable | `AWS_REGION` | e.g. `us-east-1` |
| variable | `EC2_INSTANCE_ID` | Terraform output `instance_id` |
| variable | `APP_URL` | Terraform output `app_url` (`https://<host>`) |
| variable | `ANSIBLE_INVENTORY` | `terraform -chdir=envs/mvp output -raw ansible_inventory` (no secrets in it) |
| secret | `ANSIBLE_VAULT_B64` | `base64 < ansible/group_vars/te_tengo/vault.yml` (the encrypted file) |
| secret | `ANSIBLE_VAULT_PASSWORD` | the vault password |
| secret | `DEPLOY_SSH_PRIVATE_KEY` | private half of a dedicated ed25519 key; its public half goes to `te_tengo_authorized_keys` with `from="127.0.0.1,::1",no-agent-forwarding,no-port-forwarding,no-X11-forwarding` and one operator run of `make deploy` (`--tags base` is enough) |

Protect the environment with required reviewers. The session name `te-tengo-mvp-deploy-<run id>` is required by the role's policy.

## 5. Operations
- Logs: `cd /opt/te-tengo && sudo docker compose logs -f api` (via `aws ssm start-session --target <instance>`).
- Restart one service: `sudo docker compose restart api`. Configuration changes go through Ansible (`make redeploy`), never by editing `/opt/te-tengo` by hand.
- Backups: daily at 03:30 Lima (`systemctl list-timers te-tengo-backup.timer`); on demand `make backup-now`; last 7 dumps in `/var/backups/te-tengo`, every dump in `s3://<backups bucket>/postgres/` (expires after 30 days, Terraform lifecycle).
- Restore: `sudo te-tengo-restore /var/backups/te-tengo/te-tengo-<stamp>.dump` (stops the API, recreates the database, restores, starts the API). From S3: the instance role can only **write** backups, so export short-lived operator credentials that can read the bucket first (`sudo -E te-tengo-restore s3://<bucket>/postgres/<file>` or `latest`), or copy the dump to the host. Test a restore after the first week.

## 6. Rollback
| What broke | Rollback |
|---|---|
| A new API image | Re-run **Deploy MVP** (or `make redeploy ANSIBLE_ARGS="-e te_tengo_api_tag=<previous tag>"`) with the previous tag. Flyway migrations are forward-only: if the bad release migrated the schema, restore the dump taken before it (the deploy does not take one: run `make backup-now` before any release with a migration). |
| Configuration (Caddyfile, mediamtx.yml, env) | Revert the commit in this repository and redeploy the app role; handlers reload Caddy and restart MediaMTX/API. |
| Data | `te-tengo-restore` with the latest good dump (see above). |
| The host | Terraform recreates the instance (`terraform apply -replace=...`), then `make inventory && make deploy` and restore the last dump from S3. Caddy gets a new certificate (Let's Encrypt rate limits: 5 duplicate certificates per week). |
| Certificate | Caddy renews by itself; if RTSPS still serves an old certificate, `sudo docker compose restart mediamtx`. |

## Secrets inventory
| Secret | Where it lives | On the host | Rotation |
|---|---|---|---|
| PostgreSQL password (`vault_postgres_password`) | Ansible Vault | `.env`, `api.env` (0600 root) | Change in the vault, `ALTER USER tetengo PASSWORD …` in the container, redeploy |
| JWT RS256 key pair (`vault_jwt_private_key_pem`, `vault_jwt_public_key_pem`) | Ansible Vault | `secrets/jwt-*.pem` (0600, UID 10001) | Replace both and redeploy: every session and agent token becomes invalid (apps sign in again, agents re-register by themselves) |
| MediaMTX hook secret (`vault_mediamtx_auth_secret`) | Ansible Vault | `.env` and `api.env` | Replace and redeploy (MediaMTX and the API restart together) |
| Firebase service-account key (`vault_fcm_credentials_json`) | Ansible Vault (never in git, never in `~/.config` copies) | `secrets/fcm.json` (0600, UID 10001) | New key in the Firebase console, update the vault, redeploy, delete the old key |
| GHCR token (`vault_registry_password`) | Ansible Vault | Docker credential store of root | Only if the package is private |
| Vault password | Password manager; GitHub secret `ANSIBLE_VAULT_PASSWORD` | — | `ansible-vault rekey`, update the secret |
| Deploy SSH key | GitHub secret `DEPLOY_SSH_PRIVATE_KEY`; public half in `te_tengo_authorized_keys` | `~ubuntu/.ssh/authorized_keys` | New pair, run the base role, update the secret, remove the old key |
| AWS credentials | **None on the host**: instance role through IMDSv2; GitHub uses OIDC | — | — |
| TLS private key | Generated by Caddy | `caddy-data` volume (MediaMTX reads it read-only) | Automatic with renewal |
