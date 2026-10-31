# Object storage of the stack: one Azure Storage account (StorageV2, Standard_LRS, hot tier) in the
# environment's resource group, with three private containers:
# - clips:     fall clips, their landmarks and profile photos (API TT_CLIPS_CONTENEDOR, TT_FOTOS_CONTENEDOR).
#              The household agent uploads with a SAS PUT and the app plays clips with a SAS GET, both
#              user delegation SAS minted by the API, so the container is never public and the backend
#              never relays video bytes.
# - movements: movement files of the households that consented to it (API TT_MOVIMIENTOS_CONTENEDOR).
# - backups:   off-host copies of the daily pg_dump (backup role, azcopy); they expire after
#              backups_retention_days.
#
# Nothing authenticates with the account keys: shared key access is off, the API and the backup job use
# the VM's system-assigned managed identity (Microsoft Entra ID) and the operator signs in with `az login`.
#
# Neither blob versioning nor blob soft delete is on, on purpose (the same reasoning as the S3 buckets of
# modules/te-tengo/s3.tf): deleting a clip or a movement file (consent revoked, retention) must really
# delete it, not keep it as an old version or a soft-deleted blob for days, and the dumps have their own
# retention. Only container soft delete is on: it protects against deleting a whole container by mistake
# and does not keep deleted blobs.

locals {
  # Globally unique, 3-24 lower-case letters and digits: <project><environment><storage_account_suffix>
  # without the dashes, e.g. tetengoproddata.
  storage_account_name = lower(replace("${var.project}${var.environment}${var.storage_account_suffix}", "/[^A-Za-z0-9]/", ""))

  storage_containers = {
    clips     = "clips"
    movements = "movements"
    backups   = "backups"
  }
}

resource "azurerm_storage_account" "this" {
  # checkov:skip=CKV_AZURE_35:Household agents and the app on any network upload and read through SAS URLs, so the blob endpoint must accept public networks; access needs Entra ID or a user delegation SAS.
  # checkov:skip=CKV_AZURE_59:Same reason as CKV_AZURE_35: the clients are on the Internet, without a private network to the account.
  # checkov:skip=CKV2_AZURE_33:A private endpoint costs per hour and per GB and the clients are on the Internet anyway (Azure for Students credit).
  # checkov:skip=CKV_AZURE_206:Locally redundant on purpose (cheapest); the dumps also stay on the VM (last 7), and clips are short-lived evidence, not records.
  # checkov:skip=CKV2_AZURE_1:Microsoft-managed keys on purpose: a customer-managed key needs a Key Vault (cost, operations) for no gain here.
  # checkov:skip=CKV2_AZURE_38:Blob soft delete stays off on purpose: a deleted clip (consent revoked, retention) must not survive as a soft-deleted blob. Container soft delete is on.
  # checkov:skip=CKV_AZURE_33:The account has no queue service in use; queue logging would only add cost.
  # checkov:skip=CKV2_AZURE_21:Blob read logging needs a Log Analytics workspace or another account (cost).
  # checkov:skip=CKV_AZURE_43:The name is computed (local.storage_account_name), which checkov cannot evaluate; the precondition below enforces 3-24 lower-case letters and digits.
  name                     = local.storage_account_name
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"
  access_tier              = "Hot"
  tags                     = local.tags

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  # Microsoft Entra ID only: no account keys, no SAS signed with them (only user delegation SAS).
  shared_access_key_enabled        = false
  default_to_oauth_authentication  = true
  public_network_access_enabled    = true
  cross_tenant_replication_enabled = false
  local_user_enabled               = false
  sftp_enabled                     = false

  # Shared key SAS are disabled anyway; the policy flags any SAS valid for longer than a day.
  sas_policy {
    expiration_period = "01.00:00:00"
    expiration_action = "Log"
  }

  blob_properties {
    versioning_enabled  = false
    change_feed_enabled = false

    container_delete_retention_policy {
      days = 7
    }

    # Browser clients (the PWA uploads profile photos with PUT and plays clips and photos with GET);
    # the household agent and the native app send no Origin and need no CORS.
    dynamic "cors_rule" {
      for_each = length(var.storage_cors_allowed_origins) > 0 ? [1] : []

      content {
        allowed_methods    = ["GET", "HEAD", "PUT", "OPTIONS"]
        allowed_origins    = var.storage_cors_allowed_origins
        allowed_headers    = ["content-type", "x-ms-blob-type", "x-ms-version", "x-ms-date", "x-ms-client-request-id"]
        exposed_headers    = ["content-length", "content-type", "content-range", "etag", "last-modified", "x-ms-request-id"]
        max_age_in_seconds = 3600
      }
    }
  }

  lifecycle {
    # Clips, movement files and dumps live here: a plan that would delete or replace the account (a new
    # storage_account_suffix, a destroy) stops instead (docs/terraform.md, "Teardown").
    prevent_destroy = true

    precondition {
      condition     = can(regex("^[a-z0-9]{3,24}$", local.storage_account_name))
      error_message = "The storage account name (<project><environment><storage_account_suffix> without dashes) must be 3 to 24 lower-case letters and digits; shorten storage_account_suffix."
    }
  }
}

# Containers through the management plane (storage_account_id), so Terraform needs no data-plane access
# to create them.
resource "azurerm_storage_container" "this" {
  # checkov:skip=CKV2_AZURE_21:Blob read logging needs a Log Analytics workspace or another account (cost).
  for_each = local.storage_containers

  name                  = each.value
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_management_policy" "this" {
  storage_account_id = azurerm_storage_account.this.id

  rule {
    name    = "expire-old-dumps"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["${local.storage_containers.backups}/"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.backups_retention_days
      }
    }
  }

  # Only when the team sets a retention (API TT_RETENCION_CLIPS); null keeps the clips. Uncommitted
  # blocks of an interrupted upload are discarded by the service after 7 days, so no cleanup rule is
  # needed (the S3 buckets abort incomplete multipart uploads instead).
  dynamic "rule" {
    for_each = var.clips_retention_days == null ? [] : [var.clips_retention_days]

    content {
      name    = "clips-retention"
      enabled = true

      filters {
        blob_types   = ["blockBlob"]
        prefix_match = ["${local.storage_containers.clips}/"]
      }

      actions {
        base_blob {
          delete_after_days_since_modification_greater_than = rule.value
        }
      }
    }
  }
}

# --- Access (Microsoft Entra ID roles) -------------------------------------------------------------------
# The VM's system-assigned managed identity (the API container and the backup job, through IMDS):
# - Storage Blob Data Contributor on clips and movements: SAS uploads and reads, the upload check and the
#   deletion on consent revocation and retention.
# - Storage Blob Data Contributor on backups: azcopy uploads the dumps and te-tengo-restore lists and
#   downloads them (the role also allows deleting; the lifecycle rule is what deletes old dumps).
# - Storage Blob Delegator on the account: Get User Delegation Key, which Azure only accepts at account
#   scope or above, so the API can mint user delegation SAS. It grants no data access by itself.

resource "azurerm_role_assignment" "vm_containers" {
  for_each = local.storage_containers

  scope                            = azurerm_storage_container.this[each.key].id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azurerm_linux_virtual_machine.app.identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
  description                      = "Te Tengo VM (${local.name}): ${each.key} container"
}

resource "azurerm_role_assignment" "vm_delegator" {
  scope                            = azurerm_storage_account.this.id
  role_definition_name             = "Storage Blob Delegator"
  principal_id                     = azurerm_linux_virtual_machine.app.identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
  description                      = "Te Tengo VM (${local.name}): user delegation SAS"
}

# The operator who applies (the `az login` identity) can use az and azcopy with --auth-mode login /
# `azcopy login`: data migration, inspection, manual restores.
data "azurerm_client_config" "current" {}

resource "azurerm_role_assignment" "operator" {
  count = var.grant_operator_storage_access ? 1 : 0

  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
  description          = "Te Tengo operator: data migration and manual restores"
}
