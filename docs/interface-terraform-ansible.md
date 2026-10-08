# Interface: Terraform → Ansible

Terraform (`bootstrap/`, `envs/`, `modules/te-tengo/`) creates the AWS resources. Ansible (`ansible/`, `compose/`) configures the host and deploys the Compose stack. The only handoff between them is the **inventory** that Terraform renders. This page is the contract: if a name changes here, both sides change in the same pull request.

## How the inventory is produced
```bash
make inventory                    # envs/mvp → ansible/inventory/hosts.yml (git-ignored)
make inventory ENV_DIR=envs/local # same file from the emulator run, to check its shape
```
The target runs `terraform -chdir=envs/mvp output -raw ansible_inventory`. The template is `modules/te-tengo/templates/inventory.yml.tftpl`.

## Shape
```yaml
all:
  children:
    te_tengo:                       # group name
      hosts:
        te-tengo-mvp:               # <project>-<environment>
          ansible_host: 'i-0123456789abcdef0'
          ansible_user: ubuntu
          ansible_connection: ssh
          ansible_ssh_common_args: >-
            -o ProxyCommand="aws ssm start-session --region us-east-1 --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p"
          app_hostname: '3-210-1-2.sslip.io'
          public_ip: '3.210.1.2'
          aws_region: 'us-east-1'
          memory_profile: 'small'
          instance_architecture: 'arm64'
          clips_s3_bucket: 'te-tengo-mvp-clips-123456789012'
          backup_s3_bucket: 'te-tengo-mvp-backups-123456789012'
          ses_sender: 'Te Tengo <no-responder@example.com>'
          push_provider: 'fcm'
          sns_platform_application_arn: ''
          live_view_publish_port: 8322
```

## Variables
| Variable | Type | Meaning | Used by Ansible for |
|---|---|---|---|
| group `te_tengo` | group | The single MVP host | `hosts: te_tengo` in the playbook |
| `ansible_host` | string | **mvp:** the EC2 instance id. **local (emulator):** the fake Elastic IP | SSH target; with SSM the `%h` of the ProxyCommand |
| `ansible_user` | string | Always `ubuntu` (Canonical Ubuntu 24.04 AMI) | SSH user |
| `ansible_connection` | string | Always `ssh` | — |
| `ansible_ssh_common_args` | string | Only with `inventory_transport = "ssm"` (mvp): SSH tunnelled through SSM Session Manager (`AWS-StartSSHSession`). Port 22 is **closed** in the security group | Needs the AWS CLI, the Session Manager plugin and credentials allowed to `ssm:StartSession` on the operator's machine |
| `app_hostname` | string | Public name Caddy gets a Let's Encrypt certificate for: `mvp.<zone>` with Route53, else `<ip-with-dashes>.sslip.io` | Caddyfile site address; API `CORS`/links; `TT_VIVO_URL_HLS=https://<app_hostname>/vivo`; `TT_VIVO_URL_PUBLICACION=rtsps://<app_hostname>:<live_view_publish_port>/camaras/{camaraId}` |
| `public_ip` | string | Elastic IP | Diagnostics, manual DNS records |
| `aws_region` | string | `us-east-1` | `TT_CLIPS_REGION`, `TT_SES_REGION`, `TT_SNS_REGION`, `aws s3 cp --region` in the backup job |
| `memory_profile` | `small` \| `micro` | `small` when the instance has 2 GiB or more (t4g.small), `micro` otherwise. Overridable with the Terraform variable `memory_profile` | Selects swap size, container `mem_limit`s, JVM flags, PostgreSQL settings |
| `instance_architecture` | `arm64` \| `amd64` | CPU of the instance (`arm64` for t4g) | Images must be `linux/<this>` |
| `clips_s3_bucket` | string | Private, SSE-S3 bucket of the fall clips | `TT_CLIPS_BUCKET` (leave `TT_CLIPS_ENDPOINT`, `TT_CLIPS_ACCESS_KEY`, `TT_CLIPS_SECRET_KEY` unset: the instance role signs) |
| `backup_s3_bucket` | string | Private bucket for `pg_dump` files; objects expire after 30 days | Upload target of the backup timer (`s3://<bucket>/<file>`) |
| `ses_sender` | string | `Name <address>` of the verified SES identity; empty if SES is off | `TT_SES_REMITENTE` (with `TT_CORREO_PROVEEDOR=ses`; empty → `registro`) |
| `push_provider` | `fcm` \| `sns` | `fcm` in the MVP (Firebase directly); `sns` only when Terraform `enable_sns = true` | `TT_PUSH_PROVEEDOR`. With `fcm`, Ansible must also place the Firebase key (vault) and set `TT_FCM_CREDENCIALES` |
| `sns_platform_application_arn` | string | GCM platform application; empty unless `enable_sns` | `TT_SNS_ARN_ANDROID` and `TT_SNS_ARN_IOS` (same ARN for both) |
| `live_view_publish_port` | number | MediaMTX RTSPS port opened in the security group (8322/TCP) | MediaMTX `rtspsAddress: :8322` and the Compose port mapping |

## What the instance role allows (no static AWS keys on the host)
The API container and the scripts on the host get credentials from the instance profile through IMDSv2 (`http_tokens = required`). The hop limit is **2** (Terraform variable `imds_hop_limit`) so a container on a Docker bridge network can reach IMDS: the API needs the role to sign the clip URLs and to call SES. Therefore:
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

## GitHub Actions deploy (environment `mvp`)
Terraform output `github_deploy_role_arn` → GitHub environment variable `AWS_DEPLOY_ROLE_ARN`. The role trusts only `repo:Te-Tengo-Tech/te-tengo-infra:environment:mvp`, may only `ssm:StartSession` on the instance with `AWS-StartSSHSession`, and may terminate/resume only sessions whose id starts with `te-tengo-mvp-deploy-`, so the workflow must set `role-session-name: te-tengo-mvp-deploy-${{ github.run_id }}`. Other variables the workflow needs: `EC2_INSTANCE_ID` (output `instance_id`), `AWS_REGION`, `APP_URL` (output `app_url`).

## What Terraform does not do
- No user data: Docker, swap, Caddy, MediaMTX, PostgreSQL and the API are Ansible's job.
- No secrets: JWT keys, the Firebase key, the MediaMTX authorization secret and database passwords live in Ansible Vault.
- No `compose/` content.
