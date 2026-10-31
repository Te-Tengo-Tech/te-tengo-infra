# One-time bootstrap of the Terraform remote state on Azure: a resource group, a storage account and the
# private `tfstate` container that envs/azure's `backend "azurerm"` uses (backend.hcl.example), plus the
# role the operator needs to read and write it with Microsoft Entra ID. Run once by the operator with local
# state (docs/terraform.md, "Remote state on Azure"); never by CI.
#
# Unlike the application's storage account, the state keeps old versions and soft-deleted blobs: a broken
# or deleted state file can be recovered, and the state holds no personal data.

data "azurerm_client_config" "current" {}

locals {
  tags = {
    Project     = "te-tengo"
    Environment = "shared"
    ManagedBy   = "terraform"
    Repository  = "Te-Tengo-Tech/te-tengo-infra"
    Purpose     = "terraform-state"
  }
}

resource "azurerm_resource_group" "state" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "state" {
  # checkov:skip=CKV_AZURE_35:Read and written only by the operator's Terraform from changing networks (Cloudflare WARP); access needs Microsoft Entra ID (shared keys are off).
  # checkov:skip=CKV_AZURE_59:Same reason as CKV_AZURE_35.
  # checkov:skip=CKV2_AZURE_33:A private endpoint costs per hour; the operator is not on an Azure network.
  # checkov:skip=CKV_AZURE_206:Locally redundant on purpose (cheapest); versions and soft delete cover mistakes.
  # checkov:skip=CKV2_AZURE_1:Microsoft-managed keys on purpose: a customer-managed key needs a Key Vault.
  # checkov:skip=CKV_AZURE_33:No queue service in use.
  # checkov:skip=CKV2_AZURE_21:Blob read logging needs a Log Analytics workspace (cost).
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.state.name
  location                 = azurerm_resource_group.state.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"
  access_tier              = "Hot"
  tags                     = local.tags

  min_tls_version                  = "TLS1_2"
  https_traffic_only_enabled       = true
  allow_nested_items_to_be_public  = false
  shared_access_key_enabled        = false
  default_to_oauth_authentication  = true
  public_network_access_enabled    = true
  cross_tenant_replication_enabled = false
  local_user_enabled               = false
  sftp_enabled                     = false

  sas_policy {
    expiration_period = "01.00:00:00"
    expiration_action = "Log"
  }

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = var.state_versions_retention_days
    }

    container_delete_retention_policy {
      days = var.state_versions_retention_days
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "tfstate" {
  # checkov:skip=CKV2_AZURE_21:Blob read logging needs a Log Analytics workspace (cost).
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true
  }
}

# Old state versions are kept for state_versions_retention_days, then deleted.
resource "azurerm_storage_management_policy" "state" {
  storage_account_id = azurerm_storage_account.state.id

  rule {
    name    = "expire-old-state-versions"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["${azurerm_storage_container.tfstate.name}/"]
    }

    actions {
      version {
        delete_after_days_since_creation = var.state_versions_retention_days
      }
    }
  }
}

# The operator who runs the bootstrap reads and writes the state with `use_azuread_auth = true`.
# Another operator needs the same role on the account (az role assignment create, docs/terraform.md).
resource "azurerm_role_assignment" "operator" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
  description          = "Te Tengo operator: Terraform state"
}
