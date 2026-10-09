variable "project" {
  description = "Project slug, the first part of every resource name (<project>-<environment>-*)."
  type        = string
  default     = "te-tengo"
}

variable "environment" {
  description = "Environment name, used in resource names and in the Environment tag."
  type        = string
  default     = "prod"
}

variable "location" {
  description = "Azure region of every resource, e.g. chilecentral. Must be one the subscription is allowed to deploy to (the Azure for Students subscription carries an \"Allowed resource deployment regions\" policy; envs/azure checks it, docs/terraform.md)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.location))
    error_message = "location must be an Azure region name in lower case without spaces (e.g. chilecentral)."
  }
}

variable "tags" {
  description = "Extra tags merged into the module's Project/Environment/ManagedBy/Repository tags."
  type        = map(string)
  default     = {}
}

# ----------------------------------------------------------------------------
# Host
# ----------------------------------------------------------------------------

variable "vm_size" {
  description = "VM size. Standard_B2ats_v2 (2 vCPU AMD, 1 GiB; memory profile 'tiny') is one of the B-series sizes with 750 free hours a month in Azure for Students. The upgrade path in chilecentral is Standard_B2als_v2 (2 vCPU, 4 GiB; profile 'medium'). Arm sizes (Standard_B2pts_v2) are supported but not offered in every region."
  type        = string
  default     = "Standard_B2ats_v2"

  validation {
    condition     = can(regex("^Standard_[A-Z]+[0-9]+", var.vm_size))
    error_message = "vm_size must be an Azure size name such as Standard_B2ats_v2."
  }
}

variable "instance_architecture" {
  description = "CPU architecture of the VM ('amd64' or 'arm64'). Null derives it from vm_size: a 'p' in the size's feature letters (Standard_B2pts_v2, Standard_D2ps_v5) means Arm64."
  type        = string
  default     = null

  validation {
    condition     = var.instance_architecture == null || contains(["amd64", "arm64"], coalesce(var.instance_architecture, "amd64"))
    error_message = "instance_architecture must be null, 'amd64' or 'arm64'."
  }
}

variable "memory_profile" {
  description = "Memory profile Ansible applies (tiny, micro, small, medium or large). Null derives it from the memory of vm_size (sizes the module knows: see local.vm_size_memory_gib); set it for any other size."
  type        = string
  default     = null

  validation {
    condition     = var.memory_profile == null || contains(["tiny", "micro", "small", "medium", "large"], coalesce(var.memory_profile, "small"))
    error_message = "memory_profile must be null, 'tiny', 'micro', 'small', 'medium' or 'large'."
  }
}

variable "admin_username" {
  description = "Administrator user of the VM (SSH key only). 'ubuntu' keeps the same Ansible user as the other environments."
  type        = string
  default     = "ubuntu"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.admin_username)) && !contains(["root", "admin", "administrator", "user", "test", "guest", "sys", "adm", "backup", "console", "owner", "server", "sql", "support"], var.admin_username)
    error_message = "admin_username must be a lower-case Linux user name that Azure does not reserve (root, admin, administrator, ...)."
  }
}

variable "ssh_public_key" {
  description = "OpenSSH public key installed for admin_username (operator and Ansible). Azure accepts RSA (2048 bits or more) and Ed25519 keys; password authentication is disabled."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa) [A-Za-z0-9+/=]+", var.ssh_public_key))
    error_message = "ssh_public_key must be an OpenSSH ssh-ed25519 or ssh-rsa public key."
  }
}

variable "os_disk_storage_account_type" {
  description = "OS disk type. StandardSSD_LRS (default; a 30 GB disk is billed as an E4) or Premium_LRS (with os_disk_size_gb = 64 it is a P6, the size the Azure free account offer lists). Standard_LRS (HDD) is allowed but slow for PostgreSQL."
  type        = string
  default     = "StandardSSD_LRS"

  validation {
    condition     = contains(["StandardSSD_LRS", "Premium_LRS", "Standard_LRS"], var.os_disk_storage_account_type)
    error_message = "os_disk_storage_account_type must be StandardSSD_LRS, Premium_LRS or Standard_LRS."
  }
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB (OS, Docker images, the PostgreSQL volume, local dumps). 30 is the size of the Ubuntu image; 64 with Premium_LRS is a P6."
  type        = number
  default     = 30

  validation {
    condition     = var.os_disk_size_gb >= 30 && var.os_disk_size_gb <= 1024
    error_message = "os_disk_size_gb must be between 30 and 1024."
  }
}

variable "trusted_launch" {
  description = "Secure Boot and vTPM (Trusted Launch). No extra cost; supported by the B family and Ubuntu 24.04 (docs/terraform.md). Switching it replaces the VM."
  type        = bool
  default     = true
}

# ----------------------------------------------------------------------------
# Network
# ----------------------------------------------------------------------------

variable "vnet_cidr" {
  description = "Address space of the dedicated virtual network; a single /24 subnet is carved out of it."
  type        = string
  default     = "10.50.0.0/16"

  validation {
    condition     = can(cidrsubnet(var.vnet_cidr, 8, 0))
    error_message = "vnet_cidr must be an IPv4 CIDR block of /16 to /24."
  }
}

variable "admin_cidrs" {
  description = "CIDR blocks allowed to reach SSH (22/TCP). Default: anywhere, because the operator connects through Cloudflare WARP and the deploy workflow runs on GitHub-hosted runners (no fixed addresses); SSH accepts keys only. Narrow it when the sources are known."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for cidr in var.admin_cidrs : can(cidrhost(cidr, 0))])
    error_message = "admin_cidrs must hold at least one valid CIDR block (e.g. 203.0.113.7/32 or 0.0.0.0/0)."
  }
}

variable "live_view_publish_port" {
  description = "TCP port of MediaMTX's RTSPS listener, where household agents publish the live view."
  type        = number
  default     = 8322
}

variable "live_view_publish_cidrs" {
  description = "CIDR blocks allowed to publish live view on live_view_publish_port. Households have dynamic addresses, so it is open by default; MediaMTX asks the API to authorize every publish."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.live_view_publish_cidrs) > 0 && alltrue([for cidr in var.live_view_publish_cidrs : can(cidrhost(cidr, 0))])
    error_message = "live_view_publish_cidrs must hold at least one valid CIDR block."
  }
}

# ----------------------------------------------------------------------------
# Public name
# ----------------------------------------------------------------------------

variable "app_hostname" {
  description = "Public name of the API (A record at the DNS provider pointing to the public IP, created by hand), e.g. api.tetengo.reqsai.tech. Empty serves the app on <ip-with-dashes>.sslip.io."
  type        = string
  default     = ""

  validation {
    condition     = var.app_hostname == "" || can(regex("^[A-Za-z0-9.-]+$", var.app_hostname))
    error_message = "app_hostname must be a DNS name."
  }
}

# ----------------------------------------------------------------------------
# Object storage (Cloudflare R2 or any S3-compatible store; not created here)
# ----------------------------------------------------------------------------

variable "object_storage_endpoint" {
  description = "S3 API endpoint of the object store, e.g. https://<ACCOUNT_ID>.r2.cloudflarestorage.com for Cloudflare R2. Also the host of the clip pre-signed URLs."
  type        = string

  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$", var.object_storage_endpoint))
    error_message = "object_storage_endpoint must be an https:// URL without a path."
  }
}

variable "object_storage_region" {
  description = "Signing region of the object store ('auto' for Cloudflare R2)."
  type        = string
  default     = "auto"
}

variable "object_storage_path_style" {
  description = "Path-style URLs (endpoint/bucket/key) for the clips and backups."
  type        = bool
  default     = true
}

variable "clips_bucket_name" {
  description = "Private bucket of the fall clips (API TT_CLIPS_BUCKET)."
  type        = string
}

variable "backups_bucket_name" {
  description = "Private bucket of the database dumps."
  type        = string
}

# ----------------------------------------------------------------------------
# Cost alert (optional)
# ----------------------------------------------------------------------------

variable "budget_alert_email" {
  description = "E-mail for a monthly subscription budget (80 % and 100 % of budget_amount, actual cost). Empty (default) creates no budget: Microsoft's Cost Management documentation lists Azure for Students as an unsupported offer (docs/terraform.md)."
  type        = string
  default     = ""

  validation {
    condition     = var.budget_alert_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be empty or an e-mail address."
  }
}

variable "budget_amount" {
  description = "Monthly budget in the billing currency (USD for Azure for Students)."
  type        = number
  default     = 5

  validation {
    condition     = var.budget_amount > 0
    error_message = "budget_amount must be positive."
  }
}

variable "budget_start_date" {
  description = "First day of the budget's first month (RFC 3339, e.g. 2026-10-01T00:00:00Z). Null uses the first day of the month of the first apply (later plans ignore the change)."
  type        = string
  default     = null

  validation {
    condition     = var.budget_start_date == null || can(regex("^[0-9]{4}-[0-9]{2}-01T00:00:00Z$", coalesce(var.budget_start_date, "2026-01-01T00:00:00Z")))
    error_message = "budget_start_date must be the first day of a month at 00:00:00Z."
  }
}
