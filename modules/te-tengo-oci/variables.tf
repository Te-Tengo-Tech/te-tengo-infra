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

variable "region" {
  description = "OCI region of every resource (the tenancy's home region for Always Free compute, e.g. sa-santiago-1 or sa-saopaulo-1); also written to the Ansible inventory."
  type        = string
}

variable "tenancy_ocid" {
  description = "OCID of the tenancy: availability domains and platform images are listed there."
  type        = string

  validation {
    condition     = startswith(var.tenancy_ocid, "ocid1.tenancy.")
    error_message = "tenancy_ocid must be a tenancy OCID (ocid1.tenancy.oc1..xxxx)."
  }
}

variable "compartment_ocid" {
  description = "OCID of the compartment that holds the resources. Null uses the root compartment (the tenancy)."
  type        = string
  default     = null
}

variable "freeform_tags" {
  description = "Extra free-form tags merged into the module's Project/Environment/ManagedBy/Repository tags."
  type        = map(string)
  default     = {}
}

# ----------------------------------------------------------------------------
# Host
# ----------------------------------------------------------------------------

variable "shape" {
  description = "Compute shape. VM.Standard.A1.Flex (Ampere, arm64) is the Always Free shape; images must be linux/arm64."
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "ocpus" {
  description = "OCPUs of a Flex shape. The Always Free A1 allowance is 2 OCPUs per tenancy, shared here by two VMs of 1 OCPU (docs/terraform.md)."
  type        = number
  default     = 1

  validation {
    condition     = var.ocpus >= 1
    error_message = "ocpus must be at least 1."
  }
}

variable "memory_in_gbs" {
  description = "Memory (GB) of a Flex shape. The Always Free A1 allowance is 12 GB per tenancy, shared here by two VMs of 6 GB (docs/terraform.md)."
  type        = number
  default     = 6

  validation {
    condition     = var.memory_in_gbs >= 1
    error_message = "memory_in_gbs must be at least 1."
  }
}

variable "boot_volume_size_in_gbs" {
  description = "Boot volume size in GB (OS, Docker images, the PostgreSQL volume and local dumps). Always Free covers 200 GB of boot and block volumes in total."
  type        = number
  default     = 50

  validation {
    condition     = var.boot_volume_size_in_gbs >= 50 && var.boot_volume_size_in_gbs <= 200
    error_message = "boot_volume_size_in_gbs must be between 50 and 200."
  }
}

variable "availability_domain_number" {
  description = "1-based availability domain of the instance. Regions with one AD (sa-santiago-1, sa-saopaulo-1) only have 1; in multi-AD regions try another one when A1 reports 'Out of host capacity'."
  type        = number
  default     = 1

  validation {
    condition     = var.availability_domain_number >= 1 && var.availability_domain_number <= 3
    error_message = "availability_domain_number must be 1, 2 or 3."
  }
}

variable "image_ocid" {
  description = "Explicit image OCID. Null resolves the newest Canonical Ubuntu 24.04 platform image for the shape's architecture (later image releases never replace the host)."
  type        = string
  default     = null
}

variable "ssh_public_key" {
  description = "OpenSSH public key installed for the 'ubuntu' user (operator and Ansible)."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ecdsa-sha2-nistp[0-9]+|ssh-rsa) [A-Za-z0-9+/=]+", var.ssh_public_key))
    error_message = "ssh_public_key must be an OpenSSH public key (ssh-ed25519 AAAA...)."
  }
}

variable "memory_profile" {
  description = "Memory profile Ansible applies (micro, small, medium or large). Null derives it from memory_in_gbs."
  type        = string
  default     = null

  validation {
    condition     = var.memory_profile == null || contains(["micro", "small", "medium", "large"], coalesce(var.memory_profile, "small"))
    error_message = "memory_profile must be null, 'micro', 'small', 'medium' or 'large'."
  }
}

# ----------------------------------------------------------------------------
# Network
# ----------------------------------------------------------------------------

variable "vcn_cidr" {
  description = "CIDR block of the dedicated VCN; a single /24 public subnet is carved out of it."
  type        = string
  default     = "10.40.0.0/16"
}

variable "admin_cidrs" {
  description = "CIDR blocks allowed to reach SSH (22/TCP): the operator's public address as a /32, or a self-hosted deploy runner. Port 22 is closed to everyone else."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for cidr in var.admin_cidrs : can(cidrhost(cidr, 0))])
    error_message = "admin_cidrs must hold at least one valid CIDR block (e.g. 203.0.113.7/32)."
  }
}

variable "public_ip_mode" {
  description = "'ephemeral' (assigned with the VNIC, kept while the instance is stopped, released when it is terminated) or 'reserved' (a regional public IP that survives the instance). Choose before the first apply: switching changes the address."
  type        = string
  default     = "ephemeral"

  validation {
    condition     = contains(["ephemeral", "reserved"], var.public_ip_mode)
    error_message = "public_ip_mode must be 'ephemeral' or 'reserved'."
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
}

variable "live_view_webrtc_port" {
  description = "Port of MediaMTX's WebRTC (ICE) listener, opened over UDP and TCP to everyone: the app plays live view over WebRTC from any network (WHEP signalling goes through Caddy on 443). MediaMTX accepts ICE only for sessions negotiated after an authorized WHEP request."
  type        = number
  default     = 8189

  validation {
    condition     = var.live_view_webrtc_port >= 1024 && var.live_view_webrtc_port <= 65535 && floor(var.live_view_webrtc_port) == var.live_view_webrtc_port
    error_message = "live_view_webrtc_port must be an unprivileged port (1024-65535)."
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
