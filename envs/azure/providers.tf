# Credentials come from the Azure CLI login (`az login`): nothing secret lives in this directory. The
# subscription is explicit so a CLI default pointing elsewhere is never used.
provider "azurerm" {
  subscription_id = var.subscription_id

  # Register only the resource providers this configuration uses instead of the provider's "core" set.
  resource_provider_registrations = "none"
  resource_providers_to_register  = var.budget_alert_email != "" ? ["Microsoft.Compute", "Microsoft.Network", "Microsoft.Consumption"] : ["Microsoft.Compute", "Microsoft.Network"]

  features {
    resource_group {
      # Never delete a resource group that still holds resources Terraform does not know about.
      prevent_deletion_if_contains_resources = true
    }

    virtual_machine {
      # The OS disk (and PostgreSQL on it) is deleted with the VM, as the boot volume is on OCI:
      # dump the database to R2 before a destroy or a -replace (docs/terraform.md).
      delete_os_disk_on_deletion = true
    }
  }
}
