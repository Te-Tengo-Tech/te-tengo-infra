# Credentials from the Azure CLI login (`az login`); the subscription is explicit.
provider "azurerm" {
  subscription_id = var.subscription_id

  resource_provider_registrations = "none"
  resource_providers_to_register  = ["Microsoft.Storage"]

  # Shared key access is disabled on the state account: data-plane reads go through Microsoft Entra ID.
  storage_use_azuread = true

  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}
