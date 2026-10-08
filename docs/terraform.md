# Terraform

The Te Tengo backend runs on **one VM** with PostgreSQL, the API, Caddy and MediaMTX in Docker Compose (set up by Ansible, see [interface-terraform-ansible.md](interface-terraform-ansible.md)). Production must cost (almost) nothing, so **only the VM comes from a cloud provider**:

| Piece | Where | Managed by |
|---|---|---|
| VM, network, firewall | **Oracle Cloud Infrastructure (OCI) Always Free**: one Ampere A1 VM (`envs/oci`, **active**) | Terraform |
| Clips, database dumps, Terraform state | **Cloudflare R2** (S3-compatible): three private buckets | By hand (below) |
| DNS | The registrar **Namify**: `api.tetengo.reqsai.tech` A record → VM IP | By hand (below) |
| Landing page | Cloudflare Pages | Outside this repository |
| Push | Firebase Cloud Messaging | Ansible (vault key) |
| E-mail | Generic SMTP relay (API `TT_CORREO_PROVEEDOR=smtp`) | Ansible ([ansible.md](ansible.md)) |

> **Status:** `envs/oci` is validated, linted and unit-tested with a mocked provider (`make tf-test`); it has **not been planned or applied against a real tenancy** (no account yet). `envs/mvp` (AWS) is an **inactive alternative**, never applied, verified only against the [Floci](https://github.com/floci-io/floci) emulator.

## Layout
| Path | What it is |
|---|---|
| `modules/te-tengo-oci/` | OCI resources of the active environment (below). `tests/module.tftest.hcl`: offline `terraform test` with `mock_provider "oci"` |
| `envs/oci/` | **Active.** Provider `oracle/oci` `~> 9.8` (lock file: 9.9.0); credentials from `~/.oci/config`. State in Cloudflare R2 through the S3 backend (`backend.hcl.example`) or local (`backend_override.tf`); `terraform.tfvars.example` |
| `modules/te-tengo/`, `envs/mvp/` | **Inactive AWS alternative**, reduced by default to "VM only" (EC2, security group, IAM for SSM, GitHub OIDC deploy role); S3, SES, SNS and Route53 are optional ([below](#aws-alternative-inactive)) |
| `envs/local/` | `modules/te-tengo` pointed at Floci, with every optional path switched on |
| `bootstrap/` | S3 state bucket for `envs/mvp` only (AWS) |
| `.tflint.hcl`, `.checkov.yaml` | Linter and security-scanner settings. Accepted checkov findings are skipped next to the resource with the reason |

## Resources (`modules/te-tengo-oci`)
| Area | Resources | Notes |
|---|---|---|
| Network | VCN `10.40.0.0/16`, one public `/24` subnet, internet gateway, route table | No NAT gateway, no private subnet (the database is on the host) |
| Firewall | Security list on the subnet, **stateful**: 80/TCP, 443/TCP, 443/UDP (HTTP/3) and **8322/TCP** (MediaMTX RTSPS, agents publish live view) from anywhere; **22/TCP only from `admin_cidrs`**; ICMP 3/4 (path MTU); all egress. The VCN's default security list (which opens 22 to 0.0.0.0/0) is emptied | Every public port of `compose/compose.yaml` and the Caddyfile, nothing else. Oracle's Ubuntu images also carry an iptables policy that rejects everything but SSH; the Ansible base role opens the same ports there ([ansible.md](ansible.md)) |
| Host | `VM.Standard.A1.Flex` (Ampere, arm64), **1 OCPU / 6 GB** by default (`ocpus`, `memory_in_gbs`), boot volume **50 GB** (`boot_volume_size_in_gbs`, 50–200), newest **Canonical Ubuntu 24.04 aarch64** platform image (data source, later releases ignored so they never replace the host), in-transit encryption of the boot volume, legacy IMDS endpoints off, `RESTORE_INSTANCE` on host maintenance, SSH key in the instance metadata | cloud-init only installs `python3` for Ansible; `memory_profile`: `large` (≥ 6 GB), `medium` (≥ 4), `small` (≥ 2), else `micro` |
| Address | `public_ip_mode = "ephemeral"` (default): the VNIC's public IP, kept while the instance is stopped and released when it is terminated. `"reserved"`: a regional reserved public IP assigned to the primary private IP (the VNIC then starts without one) | See [public IP](#public-ip-ephemeral-by-default) |
| Name | `app_hostname` (e.g. `api.tetengo.reqsai.tech`, A record by hand at Namify), else `<ip-with-dashes>.sslip.io` | Output `dns_record` prints the record to create |
| Tags | Free-form `Project`, `Environment`, `ManagedBy`, `Repository` | |
| Guard | `check "always_free_allowance"`: a **warning** when the host exceeds the tenancy's A1 allowance (2 OCPUs, 12 GB) or 200 GB | |

Outputs: `public_ip`, `ssh_command`, `app_url`, `dns_record`, `live_view_*`, `memory_profile`, `instance_architecture`, `image_id`, `availability_domain` and `ansible_inventory` (same contract as the AWS module, `ansible_connection: ssh` without a proxy; [interface-terraform-ansible.md](interface-terraform-ansible.md)).

## Cost: what is free and why
Read on **2026-10-08**. Only the numbers below are sourced; nothing else is assumed.

| Item | Free allowance | Source | Te Tengo uses |
|---|---|---|---|
| Ampere A1 compute | "the first 1,500 OCPU hours and 9,000 GB hours per month" for `VM.Standard.A1.Flex`, which for Always Free tenancies is "equivalent to 2 OCPUs and 12 GB of memory"; instances must be created in the **home region** | [OCI Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) | **1 OCPU / 6 GB**: the tenancy's allowance is **shared by two VMs of 1 OCPU / 6 GB each** (this one and another project's VM, created later). Together they stay inside the allowance |
| Block Volume | 200 GB of boot + block volumes combined and five volume backups, in the home region; the page gives 47 GB and 50 GB as the minimum boot volume | same page | 50 GB here (+ 50 GB for the second VM) |
| Outbound data | 10 TB per month | same page; [OCI VCN pricing](https://www.oracle.com/cloud/networking/virtual-cloud-network/pricing/) ("Customers are not charged for the first 10 TB of data egress per month") | Live view (LL-HLS) and API traffic |
| VCN, subnet, internet gateway, security list | Free Tier tenancies "can have up to 2 virtual cloud networks"; the VCN pricing page lists charges only for egress beyond 10 TB, FastConnect ports and inter-region traffic | same pages | 1 VCN (the second VM can share it or use the other one) |
| Public IPv4 | **Not listed** on the Always Free page, and no price line found for it on 2026-10-08. Reserved public IPs: limit 50 per region ([service limits](https://docs.oracle.com/en-us/iaas/Content/General/Concepts/servicelimits.htm)) | — | Ephemeral by default (comes with the VNIC); see below |
| Cloudflare R2 (Standard) | 10 GB-month of storage, 1 million Class A and 10 million Class B operations per month; egress free | [R2 pricing](https://developers.cloudflare.com/r2/pricing/) | Clips, dumps (30 days) and the Terraform state |

**Idle reclamation:** "Idle Always Free compute instances may be reclaimed by Oracle" when, over 7 days, the 95th-percentile CPU is below 20 %, network utilization is below 20 % **and**, for A1, memory utilization is below 20 % ([same page](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)). With the `large` profile the JVM heap, PostgreSQL's buffers and the page cache should keep memory above 20 % of 6 GB, but this is not measured yet: check the instance's memory metric in the console during the first week.

**Capacity:** A1 hosts are often full in popular regions ("Out of host capacity" at apply). Retry later or, in a multi-AD region, set another `availability_domain_number`; Santiago and São Paulo have a single AD.

### Public IP: ephemeral by default
The task was to use a reserved public IP if OCI documents it as Always Free. The [Always Free page](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) does not mention reserved (or ephemeral) public IPs and no Oracle price for them was found, so the module **defaults to an ephemeral IP** and offers `public_ip_mode = "reserved"` as an option. An ephemeral IP survives stop/start ("When you stop an instance, its ephemeral public IPs remain assigned to the instance") and is deleted with the instance ([Public IP Addresses](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/managingpublicIPs.htm)); after a `-replace` of the VM, update the A record at Namify. A reserved IP can only be assigned to a private IP without a public IP ([Assigning a Reserved Public IP](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/reserved-public-ip-assign.htm)), which is why the VNIC starts without one in that mode. Choose the mode before the first apply.

## Runbook: first apply on OCI (operator)
Prerequisites: Terraform ≥ 1.10, Ansible core ≥ 2.18, an OpenSSH key pair, a Cloudflare account and access to the Namify DNS panel.

1. **OCI account (you create it yourself).** Sign up at Oracle Cloud Free Tier and pick the **home region** carefully: Always Free compute only exists there and it cannot be changed later (e.g. `sa-santiago-1`, Chile Central (Santiago), or `sa-saopaulo-1`, Brazil East (São Paulo), the closest to Peru). Card verification is part of the sign-up.
2. **API signing key** ([Required Keys and OCIDs](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm)): Console → profile menu → *My profile* → *API keys* → *Add API key* → *Generate API key pair* → download the private key → *Add*. Paste the configuration preview the console shows into `~/.oci/config` (profile `[DEFAULT]`) and point `key_file` at the downloaded key (`chmod 600`). It holds `user`, `fingerprint`, `tenancy`, `region` and `key_file` ([SDK and CLI configuration file](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/sdkconfig.htm)). Never commit it.
3. **Cloudflare R2** (Dashboard → R2): create three **private** buckets (no public access, no custom domain): `te-tengo-clips`, `te-tengo-backups`, `te-tengo-tfstate`. Note the **Account ID** (R2 overview): the endpoint is `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`. Then *Manage R2 API Tokens* → create tokens with permission **Object Read & Write**, each limited to one bucket ([R2 API tokens](https://developers.cloudflare.com/r2/api/tokens/)); R2 shows the Access Key ID and Secret Access Key **once**:
   | Token | Bucket | Goes to |
   |---|---|---|
   | clips | `te-tengo-clips` | vault `vault_clips_s3_access_key_id` / `vault_clips_s3_secret_access_key` (the API signs pre-signed URLs) |
   | backups | `te-tengo-backups` | vault `vault_backup_s3_access_key_id` / `vault_backup_s3_secret_access_key` (dump upload and restore) |
   | tfstate | `te-tengo-tfstate` | operator's `~/.aws/credentials`, profile `[r2-tfstate]` (Terraform state only) |

   One token with Object Read & Write on the three buckets also works; per-bucket tokens limit the damage of a leaked key. Optional: an object lifecycle rule on `te-tengo-backups` that deletes objects after 30 days ([R2 object lifecycles](https://developers.cloudflare.com/r2/buckets/object-lifecycles/)).
4. **State backend.** R2 through Terraform's S3 backend ([Cloudflare: Remote R2 backend](https://developers.cloudflare.com/terraform/advanced-topics/remote-backend/)):
   ```bash
   cp envs/oci/backend.hcl.example envs/oci/backend.hcl   # set <ACCOUNT_ID>; bucket te-tengo-tfstate
   ```
   `backend.hcl` sets `region = "auto"`, `endpoints = { s3 = "https://<ACCOUNT_ID>.r2.cloudflarestorage.com" }`, `use_path_style = true` and `skip_credentials_validation`, `skip_metadata_api_check`, `skip_region_validation`, `skip_requesting_account_id`, `skip_s3_checksum` (R2 has no STS, IMDS, AWS region list or account id, and not every flexible checksum). Locking: `use_lockfile = true`, a conditional PUT with `If-None-Match`, which R2 lists as supported; no `encrypt`, because R2 does not implement `x-amz-server-side-encryption` and encrypts every object at rest itself ([R2 S3 API compatibility](https://developers.cloudflare.com/r2/api/s3/api/), [R2 data security](https://developers.cloudflare.com/r2/reference/data-security/)). The keys come from the `r2-tfstate` profile, never from the file. **Local state instead:** `printf 'terraform {\n  backend "local" {}\n}\n' > envs/oci/backend_override.tf` (git-ignored) and back up `envs/oci/terraform.tfstate` yourself.
5. **Variables:** `cp envs/oci/terraform.tfvars.example envs/oci/terraform.tfvars` and fill in the [variables](#variables-of-envsoci): `region`, `tenancy_ocid`, `ssh_public_key`, `admin_cidrs` (your public IP as `/32`), `app_hostname`, `object_storage_endpoint`.
6. **Plan, review, apply** (from your terminal; `oci-apply` refuses to run where `CI` or `GITHUB_ACTIONS` is set):
   ```bash
   make oci-init && make oci-plan     # review: 7 resources (8 with a reserved IP), A1.Flex 1 OCPU / 6 GB, home region
   make oci-apply
   terraform -chdir=envs/oci output public_ip dns_record ssh_command
   ```
7. **DNS at Namify:** in the DNS panel of `reqsai.tech`, add an **A** record, host `api.tetengo`, value = output `public_ip`, TTL 300 (or the lowest Namify allows). Wait until `dig +short api.tetengo.reqsai.tech` returns the IP: Let's Encrypt needs it **before** the first deploy.
8. **First SSH, host key:** `ssh ubuntu@<public_ip>` from an address in `admin_cidrs`. Compare the fingerprint with the one cloud-init prints to the serial console (Console → instance → *Console connection* / *Console history*) before accepting it; then `ssh-keyscan -t ed25519 <public_ip>` gives the line for the deploy workflow's `OCI_SSH_KNOWN_HOSTS` ([deploy.md](deploy.md)).
9. **Inventory and deploy:** `make inventory` (writes `ansible/inventory/hosts.yml` from `envs/oci`), then [deploy.md](deploy.md). Images must be `linux/arm64`.

**Teardown:** dump the database first (`make backup-now`, it lands in R2), then `terraform -chdir=envs/oci destroy`. The boot volume is deleted with the instance.

## Variables of `envs/oci`
| Variable | Default | Notes |
|---|---|---|
| `region` | — (required) | Home region, e.g. `sa-santiago-1` or `sa-saopaulo-1` |
| `oci_config_profile` | `DEFAULT` | Profile of `~/.oci/config` |
| `tenancy_ocid` | — (required) | Also lists availability domains and images |
| `compartment_ocid` | `null` | `null` = root compartment |
| `environment` | `prod` | Names `te-tengo-prod-*`, host alias `te-tengo-prod` |
| `shape` / `ocpus` / `memory_in_gbs` | `VM.Standard.A1.Flex` / `1` / `6` | Half of the A1 allowance; the other half is for a second VM |
| `boot_volume_size_in_gbs` | `50` | 50–200 |
| `availability_domain_number` | `1` | 1-based |
| `image_ocid` | `null` | `null` = newest Canonical Ubuntu 24.04 aarch64 |
| `ssh_public_key` | — (required) | `ubuntu` user |
| `admin_cidrs` | — (required) | SSH sources, e.g. `["203.0.113.7/32"]` |
| `public_ip_mode` | `ephemeral` | or `reserved` |
| `app_hostname` | `""` | `api.tetengo.reqsai.tech` in production |
| `object_storage_endpoint` | — (required) | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` |
| `object_storage_region` | `auto` | |
| `clips_bucket_name` / `backups_bucket_name` | `te-tengo-clips` / `te-tengo-backups` | |

## Checks without a cloud account
```bash
make fmt-check validate   # every configuration, terraform init -backend=false
make tf-test              # terraform test of modules/te-tengo-oci with mock_provider "oci"
make lint security        # tflint and checkov (Docker)
make local-test           # modules/te-tengo against Floci (AWS alternative)
```
`make tf-test` (6 runs) checks the default A1 host (1 OCPU, 6 GB, 50 GB, newest image, first AD, legacy IMDS off), that only 80/TCP, 443/TCP, 443/UDP and 8322/TCP are open to the Internet and 22 only to `admin_cidrs`, the emptied default security list, both public-IP modes and the sslip.io fallback, the memory profiles, the rendered inventory field by field, the Always Free warning and the input validations. It cannot prove that OCI accepts the requests (shape availability, image names, service limits): that needs the first real plan.

CI (`.github/workflows/terraform.yml`) runs all of the above with **no cloud credentials**; nothing is planned or applied against OCI or AWS.

## AWS alternative (inactive)
`envs/mvp` + `modules/te-tengo` put the same host on one EC2 `t4g.small` in `us-east-1`. It stays in the repository as a documented alternative and keeps passing `validate`, `tflint`, `checkov` and the Floci round trips, but it is **not applied**. Its defaults match the production choices: the module creates only the VM, its network, the security group, the IAM role for SSM and the GitHub OIDC deploy role; storage is R2 (`object_storage_endpoint`, `clips_bucket_name`, `backups_bucket_name` → `object_storage_auth: static` in the inventory), e-mail is the SMTP relay, DNS is a hand-made A record (`app_hostname`). `enable_s3_buckets`, `enable_ses`, `enable_sns` and `dns_zone_name` bring back the AWS-native pieces.

### Resources (`modules/te-tengo`)
Optional parts are marked with the variable that switches them on; **every one is off by default** ("VM only").
| Area | Resources | Notes |
|---|---|---|
| Network | VPC `10.30.0.0/16`, one public `/24` subnet, internet gateway, route table; the default security group is emptied | No NAT gateway, no private subnets (the database is on the host) |
| Security group | 80/TCP, 443/TCP, 443/UDP (HTTP/3) and **8322/TCP** (MediaMTX RTSPS, agents publish live view) from anywhere; all egress | **No port 22**: administration through SSM Session Manager |
| Host | EC2 `t4g.small` (arm64, 2 GiB), Canonical Ubuntu 24.04 LTS (latest AMI, then ignored so it never replaces the host), gp3 30 GiB **encrypted**, **IMDSv2 required** (hop limit 2 so the API container can use the role), **termination protection**, `cpu_credits = standard`, EBS-optimized, optional key pair for SSH over SSM | `memory_profile` output: `small` (≥ 2 GiB) or `micro` |
| Address | Elastic IP + association | Hostname: `mvp.<zone>` with an existing Route53 zone (`dns_zone_name`, default empty), else `app_hostname` (A record by hand at the registrar), else `<ip-with-dashes>.sslip.io` |
| Clips (`enable_s3_buckets`, default off: Cloudflare R2) | S3 `te-tengo-mvp-clips-<account>`: private, owner-enforced, SSE-S3, TLS only, abort incomplete uploads after 1 day; expiration only if `clips_retention_days` is set (default `null` = keep: **pending team decision**, API `TT_RETENCION_CLIPS`); CORS only if `clips_cors_allowed_origins` is set (the app and the agent are native clients and need none) | Not versioned on purpose: a deleted clip (consent revoked) must not survive as an old version |
| Backups (`enable_s3_buckets`) | S3 `te-tengo-mvp-backups-<account>`: same hardening, objects expire after **30 days** | |
| E-mail (`enable_ses`, default off: SMTP relay) | SESv2 e-mail identity `ses_sender_email`; optional domain identity `ses_domain` with Easy DKIM (CNAMEs in Route53 when the domain is in the zone, else output `ses_dkim_records`) | |
| Push | Firebase Cloud Messaging directly (API `TT_PUSH_PROVEEDOR=fcm`, no AWS resource). SNS GCM platform application behind `enable_sns = false` | |
| Instance role | `AmazonSSMManagedInstanceCore` always; with the options on: clips `ListBucket` + `Get/Put/DeleteObject`; backups `PutObject` + `AbortMultipartUpload` (write only); `ses:SendEmail`/`SendRawEmail` on the identities with `ses:FromAddress` = sender; SNS endpoint actions only with `enable_sns` | With R2 the API and the backup job use R2 keys from the Ansible vault |
| Deploy role | GitHub OIDC provider + role trusted only by `repo:Te-Tengo-Tech/te-tengo-infra:environment:mvp`; may only `ssm:StartSession` on this instance with `AWS-StartSSHSession` and terminate/resume its own `te-tengo-mvp-deploy-*` sessions | |
| Tags | `default_tags`: `Project`, `Environment`, `ManagedBy`, `Repository` | |

### Local verification with Floci
Needs Docker and Terraform ≥ 1.10. No AWS account or credentials.
```bash
make local-up        # Floci 2.2.0 on http://localhost:24566 (not 4566, to leave the API's Floci alone)
make local-plan      # plan envs/local against Floci
make local-apply     # create the 44 resources in Floci
make inventory ENV_DIR=envs/local   # render ansible/inventory/hosts.yml from the emulator
make local-destroy   # remove them
make local-down      # stop Floci (in-memory) and delete the local state
make local-test      # up + apply + destroy

```
Every `local-*` run removes `AWS_PROFILE`/`AWS_ACCESS_KEY_ID`/... from the environment and sets `HTTPS_PROXY`/`HTTP_PROXY` to a dead local port with `NO_PROXY=localhost`, so a call that misses an endpoint override **fails instead of reaching AWS**. `floci_endpoint` only accepts a `localhost`/`127.0.0.1` URL.

CI (`.github/workflows/terraform.yml`) starts Floci as a service container and runs both round trips (every option on, then "VM only"), checking the rendered inventory each time.

#### What Floci 2.2.0 emulated, and what it did not
Result on 2026-10-08: **44 resources created and 44 destroyed** with every option on, and **22 created and 22 destroyed** with the "VM only" defaults of `envs/mvp`, no errors.

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

### Cost estimate (us-east-1, on-demand, 730 h/month)
Written when S3 and SES were on by default; with the "VM only" defaults the S3 and SES lines drop out (R2 and the SMTP relay are outside AWS).
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

#### Free Plan
For accounts created **on or after 2025-07-15**, `t4g.small` is Free Tier eligible (also `t3.micro`, `t3.small`, `t4g.micro`, `c7i-flex.large`, `m7i-flex.large`). The account gets **USD 100 in sign-up credits and up to USD 100 more** for completing activities; the Free plan lasts **6 months or until the credits run out**, whichever comes first, and usage cannot exceed it (the account must move to the Paid plan to continue). Accounts created before that date keep the legacy 12-month Free Tier, where only `t2.micro`/`t3.micro` are eligible. Source: [Track your Free Tier usage for Amazon EC2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-free-tier-usage.html), read 2026-10-07. At ≈ USD 18.6/month the credits cover the whole 6-month Free plan. After `apply`, check eligibility with the output `instance_free_tier_eligible` or:
```bash
aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true --query "InstanceTypes[].InstanceType" --output text
```

### Runbook for a real apply (not run, environment inactive)
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
   cp terraform.tfvars.example terraform.tfvars  # ssh_public_key, app_hostname, R2 endpoint and buckets...
   ```
3. **Plan and review**: `make mvp-init && make mvp-plan` from the repository root. Check that the plan creates about 20 resources with the defaults (about 40 with S3 and SES on), none outside `us-east-1`, and that the instance type is `t4g.small`.
4. **Apply**: `terraform -chdir=envs/mvp apply tfplan`.
5. **SES** (only with `enable_ses`): click the verification link SES e-mails to `ses_sender_email`. A new account is in the **SES sandbox** (it only sends to verified addresses, 200 e-mails/day); for the demo, verify the presenters' addresses or request production access in the SES console. With `ses_domain` outside Route53, add the `ses_dkim_records` CNAMEs at the DNS provider.
6. **Inventory and deploy**: `make inventory ENV_DIR=envs/mvp`, then the Ansible steps. Images must be `linux/arm64` (output `instance_architecture`).
7. **GitHub environment `mvp`**: variables `AWS_DEPLOY_ROLE_ARN` (output `github_deploy_role_arn`), `EC2_INSTANCE_ID` (`instance_id`), `AWS_REGION`, `APP_URL` (`app_url`). If the account already has a GitHub OIDC provider, pass its ARN in `github_oidc_provider_arn`.
8. **Check**: `https://<app_hostname>/actuator/health` is `UP`; `aws ssm start-session --target <instance_id>` opens a shell; port 22 is closed.

**Teardown:** dump the database first. Set `termination_protection = false` and apply; with `enable_s3_buckets`, empty both buckets (`aws s3 rm s3://<bucket> --recursive`; `force_destroy_buckets` is false on purpose); then `terraform -chdir=envs/mvp destroy`. Releasing the Elastic IP stops its hourly charge.

### Variables of `envs/mvp`
| Variable | Default | Notes |
|---|---|---|
| `aws_region` | `us-east-1` | |
| `instance_type` | `t4g.small` | arm64; Free Plan eligible for new accounts |
| `root_volume_size` | `30` | GiB, gp3, encrypted |
| `cpu_credits` | `standard` | `unlimited` avoids throttling, may bill surplus |
| `termination_protection` | `true` | the database lives on the root volume |
| `ssh_public_key` | — (required) | for SSH tunnelled through SSM |
| `dns_zone_name` / `dns_record_name` | `""` / `mvp` | empty zone → `app_hostname` or sslip.io |
| `app_hostname` | `""` | A record created by hand at the registrar |
| `enable_s3_buckets` | `false` | off: Cloudflare R2 |
| `object_storage_endpoint` / `object_storage_region` | `""` / `auto` | R2 endpoint when the buckets are off |
| `clips_bucket_name` / `backups_bucket_name` | `te-tengo-clips` / `te-tengo-backups` | R2 buckets when the buckets are off |
| `clips_retention_days` | `null` | only with `enable_s3_buckets`; keep clips, pending team decision |
| `clips_cors_allowed_origins` | `[]` | only for a browser client |
| `backups_retention_days` | `30` | |
| `enable_ses` | `false` | off: SMTP relay (Ansible) |
| `ses_sender_email` / `ses_sender_name` / `ses_domain` | `""` / `Te Tengo` / `""` | only with `enable_ses` |
| `enable_sns` / `sns_fcm_service_account_json` | `false` / `null` | pass the key with `TF_VAR_sns_fcm_service_account_json`; it is stored in the state |
| `github_deploy_repository` / `github_deploy_environment` / `github_oidc_provider_arn` | `Te-Tengo-Tech/te-tengo-infra` / `mvp` / `""` | empty repository skips the deploy role |
