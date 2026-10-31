variable "subscription_id" {
  description = "Azure subscription id (GUID), the same as envs/azure: `az account show --query id -o tsv`."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a subscription GUID."
  }
}

variable "location" {
  description = "Azure region of the state account; one the subscription's policy allows (envs/azure lists them)."
  type        = string
  default     = "chilecentral"

  validation {
    condition     = contains(["canadacentral", "chilecentral", "northcentralus", "westus", "mexicocentral"], var.location)
    error_message = "location must be a region the subscription's policy allows: canadacentral, chilecentral, northcentralus, westus or mexicocentral."
  }
}

variable "resource_group_name" {
  description = "Resource group of the state account, separate from the environment's, so destroying an environment never touches its state."
  type        = string
  default     = "te-tengo-tfstate-rg"
}

variable "storage_account_name" {
  description = "Name of the state storage account: global across Azure, 3-24 lower-case letters and digits. Change it if it is taken."
  type        = string
  default     = "tetengotfstate"

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3 to 24 lower-case letters and digits."
  }
}

variable "state_versions_retention_days" {
  description = "Days deleted state blobs (soft delete) and previous state versions are kept."
  type        = number
  default     = 90

  validation {
    condition     = var.state_versions_retention_days >= 1 && var.state_versions_retention_days <= 365
    error_message = "state_versions_retention_days must be between 1 and 365."
  }
}
