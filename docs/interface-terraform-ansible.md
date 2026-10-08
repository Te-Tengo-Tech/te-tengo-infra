# Interface: Terraform → Ansible

Terraform (`envs/oci` + `modules/te-tengo-oci`, active; `envs/mvp` + `modules/te-tengo`, inactive AWS alternative) creates the VM. Ansible (`ansible/`, `compose/`) configures the host and deploys the Compose stack. The only handoff between them is the **inventory** that Terraform renders; both modules render the same contract. This page is the contract: if a name changes here, both sides change in the same pull request.

## How the inventory is produced
```bash
make inventory                     # envs/oci → ansible/inventory/hosts.yml (git-ignored)
make inventory ENV_DIR=envs/mvp    # the AWS alternative
make inventory ENV_DIR=envs/local  # same file from the emulator run, to check its shape
```
The target runs `terraform -chdir=<env> output -raw ansible_inventory`. Templates: `modules/te-tengo-oci/templates/inventory.yml.tftpl` and `modules/te-tengo/templates/inventory.yml.tftpl`.

## Shape (OCI, production)
```yaml
all:
  children:
    te_tengo:                       # group name
      hosts:
        te-tengo-prod:              # <project>-<environment>
          ansible_host: '192.0.2.10'
          ansible_user: ubuntu
          ansible_connection: ssh   # plain SSH; port 22 open only to admin_cidrs
          app_hostname: 'api.tetengo.reqsai.tech'
          public_ip: '192.0.2.10'
          cloud_provider: oci
          cloud_region: 'sa-santiago-1'
          memory_profile: 'large'
          instance_architecture: 'arm64'
          object_storage_endpoint: 'https://<ACCOUNT_ID>.r2.cloudflarestorage.com'
          object_storage_region: 'auto'
          object_storage_path_style: true
          object_storage_auth: static
          clips_s3_bucket: 'te-tengo-clips'
          backup_s3_bucket: 'te-tengo-backups'
          ses_sender: ''
          push_provider: fcm
          sns_platform_application_arn: ''
          live_view_publish_port: 8322
```
The AWS module renders the same keys plus `aws_region`, with `ansible_host` = the instance id and an SSM `ProxyCommand` in `ansible_ssh_common_args`; with `enable_s3_buckets` it sets `object_storage_endpoint: ''`, `object_storage_region` = the AWS region, `object_storage_path_style: false` and `object_storage_auth: instance_role`.

## Variables
| Variable | Type | Meaning | Used by Ansible for |
|---|---|---|---|
| group `te_tengo` | group | The single host | `hosts: te_tengo` in the playbook |
| `ansible_host` | string | **oci:** the VM's public IP. **aws:** the EC2 instance id. **local (emulator):** the fake Elastic IP | SSH target; with SSM the `%h` of the ProxyCommand |
| `ansible_user` | string | Always `ubuntu` (Canonical Ubuntu 24.04 image) | SSH user |
| `ansible_connection` | string | Always `ssh` | — |
| `ansible_ssh_common_args` | string | **aws only** (`inventory_transport = "ssm"`): SSH tunnelled through SSM Session Manager (`AWS-StartSSHSession`); port 22 is closed there | Needs the AWS CLI, the Session Manager plugin and credentials allowed to `ssm:StartSession` |
| `app_hostname` | string | Public name Caddy gets a Let's Encrypt certificate for: `app_hostname` (A record by hand at Namify), `mvp.<zone>` with Route53 (aws), else `<ip-with-dashes>.sslip.io` | Caddyfile site address; `TT_VIVO_URL_HLS=https://<app_hostname>/vivo`; `TT_VIVO_URL_PUBLICACION=rtsps://<app_hostname>:<live_view_publish_port>/camaras/{camaraId}` |
| `public_ip` | string | Public IPv4 (ephemeral or reserved on OCI, Elastic IP on AWS) | Diagnostics, the DNS record |
| `cloud_provider` / `cloud_region` | `oci` \| `aws` / string | Where the VM runs | Diagnostics |
| `aws_region` | string | **aws only** | `TT_SES_REGION`, `TT_SNS_REGION` (only with SES/SNS) |
| `memory_profile` | `micro` \| `small` \| `medium` \| `large` | **oci:** from `memory_in_gbs` (`large` for the default 6 GB). **aws:** `small` (≥ 2 GiB) or `micro`. Overridable with the module variable `memory_profile` | Selects swap size, container `mem_limit`s, JVM flags, PostgreSQL settings (`group_vars/te_tengo/memory.yml`) |
| `instance_architecture` | `arm64` \| `amd64` | CPU of the VM (`arm64` for A1 and t4g) | Images must be `linux/<this>` |
| `object_storage_endpoint` | string | S3 API endpoint of the object store: `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`; empty = Amazon S3 | `TT_CLIPS_ENDPOINT` (also the host of the pre-signed URLs); `--endpoint-url` of the backup job |
| `object_storage_region` | string | `auto` for R2, the AWS region for S3 | `TT_CLIPS_REGION`; `AWS_DEFAULT_REGION` of the backup job |
| `object_storage_path_style` | bool | `true` for R2 (`endpoint/bucket/key`) | `TT_CLIPS_PATH_STYLE`; `addressing_style` of the backup job |
| `object_storage_auth` | `static` \| `instance_role` | `static`: keys from the vault (`vault_clips_s3_*` for the API, `vault_backup_s3_*` for the backup job). `instance_role`: AWS SDK default chain (S3 buckets created by the AWS module) | `TT_CLIPS_ACCESS_KEY` / `TT_CLIPS_SECRET_KEY`; `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in `/etc/te-tengo/backup.env` |
| `clips_s3_bucket` | string | Private bucket of the fall clips | `TT_CLIPS_BUCKET` |
| `backup_s3_bucket` | string | Private bucket for `pg_dump` files | Upload target of the backup timer (`s3://<bucket>/postgres/<file>`) |
| `ses_sender` | string | `Name <address>` of a verified SES identity; empty unless the AWS module has `enable_ses` | With `te_tengo_smtp_host` empty: `TT_CORREO_PROVEEDOR=ses` + `TT_SES_REMITENTE`; else ignored |
| `push_provider` | `fcm` \| `sns` | `fcm` (Firebase directly); `sns` only with the AWS module's `enable_sns` | `TT_PUSH_PROVEEDOR`. With `fcm`, Ansible places the Firebase key (vault) and sets `TT_FCM_CREDENCIALES` |
| `sns_platform_application_arn` | string | GCM platform application; empty unless `enable_sns` | `TT_SNS_ARN_ANDROID` and `TT_SNS_ARN_IOS` |
| `live_view_publish_port` | number | MediaMTX RTSPS port opened in the firewall (8322/TCP) | MediaMTX `rtspsAddress: :8322`, the Compose port mapping and the host firewall (base role) |

E-mail through the SMTP relay is **not** part of the inventory: it is not infrastructure Terraform creates. Its host, port, security and sender live in `group_vars/te_tengo/vars.yml` (`te_tengo_smtp_*`) and its credentials in the vault ([ansible.md](ansible.md)).

## Credentials on the host
- **OCI (production):** no cloud credentials at all. The API and the backup job hold R2 tokens from the Ansible vault (0600 files, `no_log`). The OCI instance metadata service is not used by the stack.
- **AWS alternative:** see below.

## AWS alternative: what the instance role allows
Only relevant with `enable_s3_buckets`, `enable_ses` or `enable_sns` (all off by default; with them off the role only carries `AmazonSSMManagedInstanceCore`). The API container and the scripts on the host get credentials from the instance profile through IMDSv2 (`http_tokens = required`). The hop limit is **2** (Terraform variable `imds_hop_limit`) so a container on a Docker bridge network can reach IMDS: the API needs the role to sign the clip URLs and to call SES. Therefore:
- do **not** pass AWS keys to any container; the AWS SDK default chain finds the role;
- every container on the host can read the role credentials, so only run trusted images (the role is least-privilege; see below). To block a container that has no business with AWS, attach it to an `internal: true` network only, or drop `169.254.169.254` with an iptables rule in the `DOCKER-USER` chain.

| Permission | Resource | For |
|---|---|---|
| `s3:ListBucket` | clips bucket | `HeadObject` returns 404 instead of 403 for a missing clip |
| `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` | `clips/*` | Pre-signed GET/PUT URLs, upload check, deletion on consent revocation and retention |
| `s3:PutObject`, `s3:AbortMultipartUpload` | `backups/*` | Uploading dumps (write-only: restores use the operator's credentials) |
| `ses:SendEmail`, `ses:SendRawEmail` | SES identities, `ses:FromAddress` = sender | API e-mails |
| `sns:CreatePlatformEndpoint`, `sns:Publish`, `sns:Get/SetEndpointAttributes` | the platform application and its endpoints | Only when `enable_sns` |
| `AmazonSSMManagedInstanceCore` | — | Session Manager (Ansible transport, shell) |

## GitHub Actions deploy
**OCI (environment `prod`):** plain SSH with a dedicated deploy key and a pinned host key; see [deploy.md](deploy.md#4-continuous-deploys-github-actions-deployyml).

**AWS (environment `mvp`):**
Terraform output `github_deploy_role_arn` → GitHub environment variable `AWS_DEPLOY_ROLE_ARN`. The role trusts only `repo:Te-Tengo-Tech/te-tengo-infra:environment:mvp`, may only `ssm:StartSession` on the instance with `AWS-StartSSHSession`, and may terminate/resume only sessions whose id starts with `te-tengo-mvp-deploy-`, so the workflow must set `role-session-name: te-tengo-mvp-deploy-${{ github.run_id }}`. Other variables the workflow needs: `EC2_INSTANCE_ID` (output `instance_id`), `AWS_REGION`, `APP_URL` (output `app_url`).

## What Terraform does not do
- No configuration beyond the minimum: on OCI cloud-init only installs `python3`; on AWS there is no user data. Docker, swap, the host firewall, Caddy, MediaMTX, PostgreSQL and the API are Ansible's job.
- No R2 buckets, R2 tokens or DNS records: they are created by hand ([terraform.md](terraform.md#runbook-first-apply-on-oci-operator)).
- No secrets: JWT keys, the Firebase key, the R2 tokens, the SMTP credentials, the MediaMTX authorization secret and database passwords live in Ansible Vault.
- No `compose/` content.
