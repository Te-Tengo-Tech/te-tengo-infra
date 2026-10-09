variable "subscription_id" {
  description = "Azure subscription id (GUID): `az account show --query id -o tsv` after `az login`."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a subscription GUID."
  }
}

variable "location" {
  description = "Azure region. chilecentral is the closest to Peru. The subscription's \"Allowed resource deployment regions\" policy only accepts the regions listed in the validation below (docs/terraform.md)."
  type        = string
  default     = "chilecentral"

  # Regions of the Azure for Students subscription's "Allowed resource deployment regions" policy
  # assignment (read on 2026-10-08). Update the list if the policy changes.
  validation {
    condition     = contains(["canadacentral", "chilecentral", "northcentralus", "westus", "mexicocentral"], var.location)
    error_message = "location must be a region the subscription's policy allows: canadacentral, chilecentral, northcentralus, westus or mexicocentral."
  }
}

variable "environment" {
  description = "Environment name (resource names te-tengo-<environment>-*)."
  type        = string
  default     = "prod"
}

variable "vm_size" {
  description = "VM size. Standard_B2ats_v2 (2 vCPU, 1 GiB; 750 free hours a month with Azure for Students) uses the 'tiny' memory profile; the upgrade path in chilecentral is Standard_B2als_v2 (2 vCPU, 4 GiB, 'medium'). B1s/B1ms and Arm sizes are not offered there to this subscription."
  type        = string
  default     = "Standard_B2ats_v2"
}

variable "memory_profile" {
  description = "Override of the memory profile Ansible applies; null derives it from vm_size."
  type        = string
  default     = null
}

variable "admin_username" {
  description = "Administrator user of the VM (SSH key only)."
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key" {
  description = "OpenSSH public key (ssh-ed25519 or ssh-rsa) for admin_username (operator and Ansible)."
  type        = string
}

variable "os_disk_storage_account_type" {
  description = "StandardSSD_LRS (default) or Premium_LRS (P6 with os_disk_size_gb = 64)."
  type        = string
  default     = "StandardSSD_LRS"
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB (30 = E4 with Standard SSD; 64 = P6 with Premium SSD)."
  type        = number
  default     = 30
}

variable "admin_cidrs" {
  description = "CIDR blocks allowed to SSH (22/TCP). Default anywhere: the operator uses Cloudflare WARP and GitHub-hosted runners deploy; SSH accepts keys only."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "app_hostname" {
  description = "Public name of the API (A record created by hand at Namify); empty uses <ip>.sslip.io."
  type        = string
  default     = ""
}

variable "object_storage_endpoint" {
  description = "Cloudflare R2 S3 endpoint: https://<ACCOUNT_ID>.r2.cloudflarestorage.com."
  type        = string
}

variable "object_storage_region" {
  description = "Signing region of the object store ('auto' for R2)."
  type        = string
  default     = "auto"
}

variable "clips_bucket_name" {
  description = "Private R2 bucket of the fall clips."
  type        = string
  default     = "te-tengo-clips"
}

variable "backups_bucket_name" {
  description = "Private R2 bucket of the database dumps."
  type        = string
  default     = "te-tengo-backups"
}

variable "budget_alert_email" {
  description = "E-mail of an optional monthly budget alert (80 % and 100 %); empty creates no budget. Azure for Students is listed as unsupported by Cost Management (docs/terraform.md)."
  type        = string
  default     = ""
}

variable "budget_amount" {
  description = "Monthly budget in USD."
  type        = number
  default     = 5
}
