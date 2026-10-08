variable "project" {
  description = "Project slug, the first part of every resource name (<project>-<environment>-*)."
  type        = string
  default     = "te-tengo"
}

variable "environment" {
  description = "Environment name, used in resource names and in the Environment tag."
  type        = string
  default     = "mvp"
}

variable "aws_region" {
  description = "AWS region of every resource; also written to the Ansible inventory."
  type        = string
}

# ----------------------------------------------------------------------------
# Host
# ----------------------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type. t4g.small (2 vCPU Graviton, 2 GiB) is Free Plan eligible for accounts created on or after 2025-07-15; Graviton types need linux/arm64 images."
  type        = string
  default     = "t4g.small"
}

variable "instance_type_facts" {
  description = "Architectures, memory (MiB) and burstable flag of instance_type. Null reads them from EC2 DescribeInstanceTypes; set them only where that call is unavailable (the Floci emulator)."
  type = object({
    architectures = list(string)
    memory_mib    = number
    burstable     = bool
  })
  default = null
}

variable "availability_zone" {
  description = "Availability zone of the public subnet and the instance. Null picks the first zone that offers instance_type."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "CIDR block of the dedicated VPC; a single /24 public subnet is carved out of it."
  type        = string
  default     = "10.30.0.0/16"
}

variable "ami_id" {
  description = "Explicit AMI id. Null resolves the latest Canonical Ubuntu 24.04 LTS AMI for the instance architecture."
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = "Size in GiB of the encrypted gp3 root volume (OS, Docker images, the PostgreSQL volume and local dumps)."
  type        = number
  default     = 30

  validation {
    condition     = var.root_volume_size >= 20
    error_message = "root_volume_size must be at least 20 GiB."
  }
}

variable "cpu_credits" {
  description = "Credit option for burstable instances: 'standard' never bills surplus credits, 'unlimited' avoids throttling but may bill surplus CPU."
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "unlimited"], var.cpu_credits)
    error_message = "cpu_credits must be 'standard' or 'unlimited'."
  }
}

variable "memory_profile" {
  description = "Memory profile Ansible applies ('small' or 'micro'). Null derives it from the instance memory: 'small' with 2 GiB or more, 'micro' otherwise."
  type        = string
  default     = null

  validation {
    condition     = var.memory_profile == null || contains(["small", "micro"], coalesce(var.memory_profile, "small"))
    error_message = "memory_profile must be null, 'small' or 'micro'."
  }
}

variable "termination_protection" {
  description = "EC2 API termination protection. PostgreSQL lives on the root volume, so keep it on; set it to false and apply before a destroy."
  type        = bool
  default     = true
}

variable "imds_hop_limit" {
  description = "IMDSv2 PUT response hop limit. 2 lets containers on a Docker bridge network (the API) use the instance role; 1 restricts it to processes on the host."
  type        = number
  default     = 2

  validation {
    condition     = var.imds_hop_limit >= 1 && var.imds_hop_limit <= 3
    error_message = "imds_hop_limit must be between 1 and 3."
  }
}

variable "ssh_public_key" {
  description = "OpenSSH public key installed for the 'ubuntu' user. Ansible connects with the matching private key through SSH tunnelled over SSM (port 22 stays closed). Null creates no key pair."
  type        = string
  default     = null
}

variable "inventory_transport" {
  description = "How the rendered Ansible inventory reaches the host: 'ssm' (ansible_host is the instance id, SSH through an SSM ProxyCommand) or 'direct' (ansible_host is the Elastic IP; for emulators and tests only, port 22 is never opened)."
  type        = string
  default     = "ssm"

  validation {
    condition     = contains(["ssm", "direct"], var.inventory_transport)
    error_message = "inventory_transport must be 'ssm' or 'direct'."
  }
}

# ----------------------------------------------------------------------------
# Network exposure
# ----------------------------------------------------------------------------

variable "live_view_publish_port" {
  description = "TCP port of MediaMTX's RTSPS listener, where household agents publish the live view."
  type        = number
  default     = 8322
}

variable "live_view_publish_cidrs" {
  description = "CIDR blocks allowed to publish live view on live_view_publish_port. Households have dynamic addresses, so it is open by default; MediaMTX asks the API to authorize every publish."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ----------------------------------------------------------------------------
# DNS
# ----------------------------------------------------------------------------

variable "dns_zone_name" {
  description = "Existing public Route53 hosted zone (e.g. tetengo.tech). Empty (default) skips Route53: the name comes from app_hostname (record created by hand at the registrar) or <elastic-ip-with-dashes>.sslip.io."
  type        = string
  default     = ""
}

variable "dns_record_name" {
  description = "Label of the A record created in dns_zone_name (e.g. 'mvp' -> mvp.<zone>). Ignored when dns_zone_name is empty."
  type        = string
  default     = "mvp"
}

# ----------------------------------------------------------------------------
# Storage
# ----------------------------------------------------------------------------

variable "app_hostname" {
  description = "Public name of the API when dns_zone_name is empty: an A record created by hand at the DNS provider (e.g. api.tetengo.reqsai.tech). Empty serves the app on <elastic-ip-with-dashes>.sslip.io."
  type        = string
  default     = ""
}

variable "enable_s3_buckets" {
  description = "Create the private S3 buckets for clips and backups and grant the instance role access. Off by default: storage lives in Cloudflare R2 (object_storage_endpoint, clips_bucket_name, backups_bucket_name)."
  type        = bool
  default     = false
}

variable "object_storage_endpoint" {
  description = "S3 API endpoint of the external object store when enable_s3_buckets is false, e.g. https://<ACCOUNT_ID>.r2.cloudflarestorage.com. Written to the Ansible inventory; its keys go to the Ansible vault."
  type        = string
  default     = ""
}

variable "object_storage_region" {
  description = "Signing region of the external object store ('auto' for Cloudflare R2). Ignored when enable_s3_buckets is true (the AWS region is used)."
  type        = string
  default     = "auto"
}

variable "clips_bucket_name" {
  description = "External bucket of the fall clips when enable_s3_buckets is false."
  type        = string
  default     = ""
}

variable "backups_bucket_name" {
  description = "External bucket of the database dumps when enable_s3_buckets is false."
  type        = string
  default     = ""
}

variable "clips_retention_days" {
  description = "Days after which fall clips expire in S3. Null keeps them: retention is a pending team decision (API: TT_RETENCION_CLIPS). Keep it at or above the API retention, as a backstop."
  type        = number
  default     = null

  validation {
    condition     = var.clips_retention_days == null || coalesce(var.clips_retention_days, 1) >= 1
    error_message = "clips_retention_days must be null or at least 1."
  }
}

variable "clips_cors_allowed_origins" {
  description = "Origins allowed to GET clips through pre-signed URLs from a browser. The mobile app and the desktop agent are native clients and need none, so the default creates no CORS rule."
  type        = list(string)
  default     = []
}

variable "backups_retention_days" {
  description = "Days after which database dumps in the backups bucket expire."
  type        = number
  default     = 30

  validation {
    condition     = var.backups_retention_days >= 1
    error_message = "backups_retention_days must be at least 1."
  }
}

variable "force_destroy_buckets" {
  description = "Let terraform destroy delete non-empty buckets. Keep false for real environments; the emulator environment sets it."
  type        = bool
  default     = false
}

# ----------------------------------------------------------------------------
# E-mail and push
# ----------------------------------------------------------------------------

variable "enable_ses" {
  description = "Create the SES sender identities and grant the instance role ses:SendEmail on them. Off by default: the API sends through an SMTP relay configured in Ansible."
  type        = bool
  default     = false
}

variable "ses_sender_email" {
  description = "E-mail address the API sends from (TT_SES_REMITENTE); SES e-mails a verification link to it. Required when enable_ses is true."
  type        = string
  default     = ""

  validation {
    condition     = var.ses_sender_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.ses_sender_email))
    error_message = "ses_sender_email must be an e-mail address."
  }
}

variable "ses_sender_name" {
  description = "Display name of the sender, rendered as '<name> <<email>>'."
  type        = string
  default     = "Te Tengo"
}

variable "ses_domain" {
  description = "Optional domain identity with Easy DKIM (e.g. tetengo.tech). Its DKIM CNAMEs are created when the domain is inside dns_zone_name; otherwise add them at your DNS provider (output ses_dkim_records)."
  type        = string
  default     = ""
}

variable "enable_sns" {
  description = "Create an SNS platform application (GCM/FCM v1) for the 'sns' push provider and grant the instance role access to its endpoints. The MVP sends through Firebase directly, so it is off."
  type        = bool
  default     = false
}

variable "sns_fcm_service_account_json" {
  description = "Firebase service-account JSON key used as the SNS platform credential. Only read when enable_sns is true; it ends up in the Terraform state."
  type        = string
  default     = null
  sensitive   = true
}

# ----------------------------------------------------------------------------
# GitHub Actions deploy role
# ----------------------------------------------------------------------------

variable "github_deploy_repository" {
  description = "GitHub repository (owner/name) whose deploy workflow may assume the deploy role through OIDC. Empty skips the OIDC provider and the role."
  type        = string
  default     = "Te-Tengo-Tech/te-tengo-infra"
}

variable "github_deploy_environment" {
  description = "GitHub Actions environment the deploy job runs in; only tokens with sub repo:<repository>:environment:<this> can assume the role."
  type        = string
  default     = "mvp"
}

variable "github_oidc_provider_arn" {
  description = "ARN of an existing token.actions.githubusercontent.com OIDC provider. Empty creates one (an account holds a single provider per URL)."
  type        = string
  default     = ""
}
