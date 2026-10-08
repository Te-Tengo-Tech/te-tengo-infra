variable "aws_region" {
  description = "AWS region of the MVP."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (resource names te-tengo-<environment>-*)."
  type        = string
  default     = "mvp"
}

variable "instance_type" {
  description = "EC2 instance type (t4g.small: arm64, 2 GiB, Free Plan eligible for accounts created on or after 2025-07-15)."
  type        = string
  default     = "t4g.small"
}

variable "root_volume_size" {
  description = "Root gp3 volume size in GiB."
  type        = number
  default     = 30
}

variable "cpu_credits" {
  description = "Burstable credit option: 'standard' or 'unlimited'."
  type        = string
  default     = "standard"
}

variable "termination_protection" {
  description = "EC2 termination protection (the database lives on the root volume)."
  type        = bool
  default     = true
}

variable "ssh_public_key" {
  description = "OpenSSH public key for the 'ubuntu' user, used by Ansible through SSH over SSM."
  type        = string
}

variable "dns_zone_name" {
  description = "Existing public Route53 zone; empty serves the app on <ip>.sslip.io."
  type        = string
  default     = ""
}

variable "dns_record_name" {
  description = "Label of the A record inside dns_zone_name."
  type        = string
  default     = "mvp"
}

variable "clips_retention_days" {
  description = "Days before clips expire; null keeps them (pending team decision)."
  type        = number
  default     = null
}

variable "clips_cors_allowed_origins" {
  description = "Browser origins allowed to GET clips; empty for native clients only."
  type        = list(string)
  default     = []
}

variable "backups_retention_days" {
  description = "Days before database dumps expire."
  type        = number
  default     = 30
}

variable "ses_sender_email" {
  description = "Sender address of the API e-mails (verified by SES)."
  type        = string
}

variable "ses_sender_name" {
  description = "Sender display name."
  type        = string
  default     = "Te Tengo"
}

variable "ses_domain" {
  description = "Optional SES domain identity with Easy DKIM."
  type        = string
  default     = ""
}

variable "enable_sns" {
  description = "Create the SNS GCM platform application (push through SNS instead of Firebase directly)."
  type        = bool
  default     = false
}

variable "sns_fcm_service_account_json" {
  description = "Firebase service-account JSON key for SNS; only with enable_sns. Pass it with TF_VAR_sns_fcm_service_account_json, never in a file in the repository."
  type        = string
  default     = null
  sensitive   = true
}

variable "github_deploy_repository" {
  description = "Repository allowed to assume the deploy role through OIDC; empty skips it."
  type        = string
  default     = "Te-Tengo-Tech/te-tengo-infra"
}

variable "github_deploy_environment" {
  description = "GitHub Actions environment of the deploy job."
  type        = string
  default     = "mvp"
}

variable "github_oidc_provider_arn" {
  description = "Existing GitHub OIDC provider ARN; empty creates one."
  type        = string
  default     = ""
}
