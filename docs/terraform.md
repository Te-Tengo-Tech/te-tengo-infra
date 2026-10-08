# Terraform: the MVP on one EC2 instance

The Te Tengo MVP for the progress presentation runs on **one EC2 `t4g.small`** in `us-east-1`, with PostgreSQL, the API, Caddy and MediaMTX in Docker Compose on that host (set up by Ansible, see [interface-terraform-ansible.md](interface-terraform-ansible.md)). Terraform creates only the AWS resources around it. The layout mirrors ReqsAI's `envs/ec2-compose`.

> **Status:** verified only against the [Floci](https://github.com/floci-io/floci) AWS emulator. Nothing has been applied to a real AWS account. The [runbook](#runbook-for-a-real-apply-not-run-yet) is for later.

## Layout
| Path | What it is |
|---|---|
| `bootstrap/` | S3 bucket for the Terraform state of every other configuration: versioned, SSE-S3, public access blocked, TLS-only policy, old versions expire after 90 days. Locking uses S3 lock files (`use_lockfile = true`, Terraform ≥ 1.10), **no DynamoDB table**. Its own state is local; applied once per account |
| `modules/te-tengo/` | Every resource of the environment (below) |
| `envs/mvp/` | Real AWS. S3 backend with partial configuration: `backend.hcl.example` → `backend.hcl` (git-ignored); `terraform.tfvars.example` → `terraform.tfvars` |
| `envs/local/` | The same module pointed at Floci: endpoint overrides for every service used, `test`/`test` keys, `skip_credentials_validation`, `skip_metadata_api_check`, `s3_use_path_style`, local backend. It also turns on the optional paths (SNS, Route53 zone, SES domain, CORS, clip retention) so they are exercised |
| `.tflint.hcl`, `.checkov.yaml` | Linter and security-scanner settings. Accepted checkov findings are skipped next to the resource with the reason |

## Resources (`modules/te-tengo`)
| Area | Resources | Notes |
|---|---|---|
| Network | VPC `10.30.0.0/16`, one public `/24` subnet, internet gateway, route table; the default security group is emptied | No NAT gateway, no private subnets (the database is on the host) |
| Security group | 80/TCP, 443/TCP, 443/UDP (HTTP/3) and **8322/TCP** (MediaMTX RTSPS, agents publish live view) from anywhere; all egress | **No port 22**: administration through SSM Session Manager |
| Host | EC2 `t4g.small` (arm64, 2 GiB), Canonical Ubuntu 24.04 LTS (latest AMI, then ignored so it never replaces the host), gp3 30 GiB **encrypted**, **IMDSv2 required** (hop limit 2 so the API container can use the role), **termination protection**, `cpu_credits = standard`, EBS-optimized, optional key pair for SSH over SSM | `memory_profile` output: `small` (≥ 2 GiB) or `micro` |
| Address | Elastic IP + association | Hostname: `mvp.<zone>` with an existing Route53 zone (`dns_zone_name`), else `<ip-with-dashes>.sslip.io` |
| Clips | S3 `te-tengo-mvp-clips-<account>`: private, owner-enforced, SSE-S3, TLS only, abort incomplete uploads after 1 day; expiration only if `clips_retention_days` is set (default `null` = keep: **pending team decision**, API `TT_RETENCION_CLIPS`); CORS only if `clips_cors_allowed_origins` is set (the app and the agent are native clients and need none) | Not versioned on purpose: a deleted clip (consent revoked) must not survive as an old version |
| Backups | S3 `te-tengo-mvp-backups-<account>`: same hardening, objects expire after **30 days** | |
| E-mail | SESv2 e-mail identity `ses_sender_email`; optional domain identity `ses_domain` with Easy DKIM (CNAMEs in Route53 when the domain is in the zone, else output `ses_dkim_records`) | |
| Push | Firebase Cloud Messaging directly (API `TT_PUSH_PROVEEDOR=fcm`, no AWS resource). SNS GCM platform application behind `enable_sns = false` | |
| Instance role | `AmazonSSMManagedInstanceCore`; clips `ListBucket` + `Get/Put/DeleteObject`; backups `PutObject` + `AbortMultipartUpload` (write only); `ses:SendEmail`/`SendRawEmail` on the identities with `ses:FromAddress` = sender; SNS endpoint actions only with `enable_sns` | No static AWS keys on the host |
| Deploy role | GitHub OIDC provider + role trusted only by `repo:Te-Tengo-Tech/te-tengo-infra:environment:mvp`; may only `ssm:StartSession` on this instance with `AWS-StartSSHSession` and terminate/resume its own `te-tengo-mvp-deploy-*` sessions | |
| Tags | `default_tags`: `Project`, `Environment`, `ManagedBy`, `Repository` | |

## Local verification with Floci
Needs Docker and Terraform ≥ 1.10. No AWS account or credentials.
```bash
make local-up        # Floci 2.2.0 on http://localhost:24566 (not 4566, to leave the API's Floci alone)
make local-plan      # plan envs/local against Floci
make local-apply     # create the 44 resources in Floci
make inventory ENV_DIR=envs/local   # render ansible/inventory/hosts.yml from the emulator
make local-destroy   # remove them
make local-down      # stop Floci (in-memory) and delete the local state
make local-test      # up + apply + destroy

make fmt validate lint security     # static checks (tflint and checkov run in Docker)
```
Every `local-*` run removes `AWS_PROFILE`/`AWS_ACCESS_KEY_ID`/... from the environment and sets `HTTPS_PROXY`/`HTTP_PROXY` to a dead local port with `NO_PROXY=localhost`, so a call that misses an endpoint override **fails instead of reaching AWS**. `floci_endpoint` only accepts a `localhost`/`127.0.0.1` URL.

CI (`.github/workflows/terraform.yml`) runs `fmt`, `validate`, `tflint`, `checkov`, and a job that starts Floci as a service container, runs `local-apply`, checks the rendered inventory and runs `local-destroy`.

### What Floci 2.2.0 emulated, and what it did not
Result on 2026-10-07: `make local-test` → **44 resources created and 44 destroyed**, no errors.

| Emulated | Gap and how it is handled |
|---|---|
| VPC, subnet, internet gateway, route table, default security group, security group rules, key pair, EC2 instance, Elastic IP and association | **No real VM**: nothing boots, so SSM, IMDS, the hop limit and Ansible cannot be tested here |
| AMI lookup (Floci ships a Canonical Ubuntu 24.04 arm64 image) and `DescribeInstanceTypeOfferings` | The provider's `aws_ec2_instance_type` data source finds **no match** in Floci's `DescribeInstanceTypes` answer (the AWS CLI parses it). `envs/local` passes `instance_type_facts` (arm64, 2048 MiB, burstable) instead; `envs/mvp` keeps the real lookup. `instance_free_tier_eligible` is therefore `null` locally |
| — | Floci does not keep `ebs_optimized`, the root volume's `encrypted`, `volume_size` and tags. The apply succeeds, but **a second plan wants to replace the instance**; the emulator run is not idempotent. Encryption and size are only proven by the request Terraform sends |
| IAM roles, inline and managed policies, instance profile, OIDC provider | Floci stores policies but **does not evaluate them**: least privilege and the OIDC trust are reviewed, not tested |
| S3 buckets, public access block, ownership, SSE, bucket policy, lifecycle, CORS | Provider 6.x reads bucket tags through **S3 Control**; without an `s3control` endpoint override that call leaves for AWS. `envs/local` overrides it and the Makefile's dead proxy guards against similar misses |
| SESv2 e-mail and domain identities, DKIM tokens | Floci marks the e-mail identity verified at once; real SES sends a verification link and starts in the sandbox |
| SNS GCM platform application | Floci does not validate the Firebase credential (a dummy JSON is used) |
| Route53 zone, A record, DKIM CNAMEs | The zone is created by `envs/local`; in `envs/mvp` it must already exist |
| STS `GetCallerIdentity` (account `000000000000`) | `skip_requesting_account_id` stays **false** in `envs/local`: with `true` the provider builds SES identity ARNs without the account (`arn:aws:ses:us-east-1::identity/...`), Floci rejects them, and Terraform 1.16.3 crashed while saving state. The lookup goes to Floci's STS |

## Cost estimate (us-east-1, on-demand, 730 h/month)
Prices read on **2026-10-07** from the AWS pricing pages and the public AWS Price List files behind them. Taxes excluded.

| Item | Price | Assumption | USD/month |
|---|---|---|---|
| EC2 `t4g.small` Linux | $0.0168/h ([EC2 On-Demand pricing](https://aws.amazon.com/ec2/pricing/on-demand/), Price List publication 2026-10-07) | 24×7 | **12.26** |
| EBS gp3 | $0.08/GB-month, 3,000 IOPS and 125 MB/s included ([EBS pricing](https://aws.amazon.com/ebs/pricing/)) | 30 GiB | **2.40** |
| Public IPv4 (Elastic IP in use) | $0.005/h ([VPC pricing, Public IPv4 tab](https://aws.amazon.com/vpc/pricing/), Price List 2026-09-17) | 1 address | **3.65** |
| S3 Standard | $0.023/GB-month; $0.005 per 1,000 PUT; $0.0004 per 1,000 GET ([S3 pricing](https://aws.amazon.com/s3/pricing/), Price List 2026-09-28) | 5 GB clips + 1.5 GB dumps, a few thousand requests | **≈ 0.17** |
| SES | $0.10 per 1,000 e-mails ([SES pricing](https://aws.amazon.com/ses/pricing/), Price List 2026-09-11) | < 1,000 e-mails | **≤ 0.10** |
| Data transfer out | First 100 GB/month free, aggregated across services and regions; then $0.09/GB ([EC2 On-Demand pricing, Data Transfer](https://aws.amazon.com/ec2/pricing/on-demand/)) | Live view (480p, ~8 fps) + clip downloads from S3, well under 100 GB | **0** |
| SSM Session Manager, IAM, security groups | No charge | | 0 |
| Route53 (optional) | $0.50 per hosted zone-month ([Route 53 pricing](https://aws.amazon.com/route53/pricing/)) | only with `dns_zone_name`; sslip.io is free | 0 – 0.50 |
| SNS (off) | — | `enable_sns = false` | 0 |
| **Total** | | | **≈ 18.6 USD/month** (≈ 0.61 USD/day) |

### Free Plan
For accounts created **on or after 2025-07-15**, `t4g.small` is Free Tier eligible (also `t3.micro`, `t3.small`, `t4g.micro`, `c7i-flex.large`, `m7i-flex.large`). The account gets **USD 100 in sign-up credits and up to USD 100 more** for completing activities; the Free plan lasts **6 months or until the credits run out**, whichever comes first, and usage cannot exceed it (the account must move to the Paid plan to continue). Accounts created before that date keep the legacy 12-month Free Tier, where only `t2.micro`/`t3.micro` are eligible. Source: [Track your Free Tier usage for Amazon EC2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-free-tier-usage.html), read 2026-10-07. At ≈ USD 18.6/month the credits cover the whole 6-month Free plan. After `apply`, check eligibility with the output `instance_free_tier_eligible` or:
```bash
aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true --query "InstanceTypes[].InstanceType" --output text
```

## Runbook for a real apply (not run yet)
Prerequisites: an AWS account (the team's, not a personal one), the AWS CLI v2 with the Session Manager plugin, Terraform ≥ 1.10, credentials of an administrator through IAM Identity Center (`aws sso login --profile te-tengo`), and an OpenSSH key pair for the deploy user.

1. **State bucket (once per account)**
   ```bash
   export AWS_PROFILE=te-tengo AWS_REGION=us-east-1
   cd bootstrap && cp terraform.tfvars.example terraform.tfvars
   terraform init && terraform plan -out=tfplan && terraform apply tfplan
   terraform output state_bucket_name
   ```
   Back up `bootstrap/terraform.tfstate` (team password manager). The bucket has `prevent_destroy`.
2. **Environment configuration**
   ```bash
   cd ../envs/mvp
   cp backend.hcl.example backend.hcl            # bucket = the output above
   cp terraform.tfvars.example terraform.tfvars  # ssh_public_key, ses_sender_email, dns_zone_name...
   ```
3. **Plan and review**: `make mvp-init && make mvp-plan` from the repository root. Check that the plan creates about 40 resources, none outside `us-east-1`, and that the instance type is `t4g.small`.
4. **Apply**: `terraform -chdir=envs/mvp apply tfplan`.
5. **SES**: click the verification link SES e-mails to `ses_sender_email`. A new account is in the **SES sandbox** (it only sends to verified addresses, 200 e-mails/day); for the demo, verify the presenters' addresses or request production access in the SES console. With `ses_domain` outside Route53, add the `ses_dkim_records` CNAMEs at the DNS provider.
6. **Inventory and deploy**: `make inventory`, then the Ansible steps. Images must be `linux/arm64` (output `instance_architecture`).
7. **GitHub environment `mvp`**: variables `AWS_DEPLOY_ROLE_ARN` (output `github_deploy_role_arn`), `EC2_INSTANCE_ID` (`instance_id`), `AWS_REGION`, `APP_URL` (`app_url`). If the account already has a GitHub OIDC provider, pass its ARN in `github_oidc_provider_arn`.
8. **Check**: `https://<app_hostname>/actuator/health` is `UP`; `aws ssm start-session --target <instance_id>` opens a shell; port 22 is closed.

**Teardown:** dump the database first. Set `termination_protection = false` and apply; empty both buckets (`aws s3 rm s3://<bucket> --recursive`; `force_destroy_buckets` is false on purpose); then `terraform -chdir=envs/mvp destroy`. Releasing the Elastic IP stops its hourly charge.

## Variables of `envs/mvp`
| Variable | Default | Notes |
|---|---|---|
| `aws_region` | `us-east-1` | |
| `instance_type` | `t4g.small` | arm64; Free Plan eligible for new accounts |
| `root_volume_size` | `30` | GiB, gp3, encrypted |
| `cpu_credits` | `standard` | `unlimited` avoids throttling, may bill surplus |
| `termination_protection` | `true` | the database lives on the root volume |
| `ssh_public_key` | — (required) | for SSH tunnelled through SSM |
| `dns_zone_name` / `dns_record_name` | `""` / `mvp` | empty zone → sslip.io |
| `clips_retention_days` | `null` | keep clips; pending team decision |
| `clips_cors_allowed_origins` | `[]` | only for a browser client |
| `backups_retention_days` | `30` | |
| `ses_sender_email` / `ses_sender_name` / `ses_domain` | — / `Te Tengo` / `""` | |
| `enable_sns` / `sns_fcm_service_account_json` | `false` / `null` | pass the key with `TF_VAR_sns_fcm_service_account_json`; it is stored in the state |
| `github_deploy_repository` / `github_deploy_environment` / `github_oidc_provider_arn` | `Te-Tengo-Tech/te-tengo-infra` / `mvp` / `""` | empty repository skips the deploy role |
