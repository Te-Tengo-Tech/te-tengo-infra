variable "region" {
  description = "OCI region: the tenancy's home region (Always Free compute only exists there), e.g. sa-santiago-1 (Santiago) or sa-saopaulo-1 (São Paulo), the closest to Peru."
  type        = string
}

variable "oci_config_profile" {
  description = "Profile of ~/.oci/config with the API signing key (user OCID, fingerprint, key file, tenancy)."
  type        = string
  default     = "DEFAULT"
}

variable "tenancy_ocid" {
  description = "OCID of the tenancy (Profile > Tenancy in the OCI console; also `tenancy` in ~/.oci/config)."
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment for the resources; null uses the root compartment."
  type        = string
  default     = null
}

variable "environment" {
  description = "Environment name (resource names te-tengo-<environment>-*)."
  type        = string
  default     = "prod"
}

variable "shape" {
  description = "Compute shape (VM.Standard.A1.Flex is the Always Free Ampere shape)."
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "ocpus" {
  description = "OCPUs (Always Free A1: 2 per tenancy, shared with a second VM: 1 each)."
  type        = number
  default     = 1
}

variable "memory_in_gbs" {
  description = "Memory in GB (Always Free A1: 12 per tenancy, shared with a second VM: 6 each)."
  type        = number
  default     = 6
}

variable "boot_volume_size_in_gbs" {
  description = "Boot volume in GB (Always Free: 200 GB of boot and block volumes in total)."
  type        = number
  default     = 50
}

variable "availability_domain_number" {
  description = "1-based availability domain; try another one in multi-AD regions on 'Out of host capacity'."
  type        = number
  default     = 1
}

variable "image_ocid" {
  description = "Explicit image OCID; null uses the newest Canonical Ubuntu 24.04 aarch64 platform image."
  type        = string
  default     = null
}

variable "ssh_public_key" {
  description = "OpenSSH public key for the 'ubuntu' user (operator and Ansible)."
  type        = string
}

variable "admin_cidrs" {
  description = "CIDR blocks allowed to SSH (22/TCP), e.g. [\"<your public IP>/32\"]."
  type        = list(string)
}

variable "public_ip_mode" {
  description = "'ephemeral' (default) or 'reserved'; see docs/terraform.md before changing it."
  type        = string
  default     = "ephemeral"
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
