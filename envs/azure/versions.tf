terraform {
  required_version = ">= 1.10.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.11"
    }
  }

  # Partial configuration: the state goes to a private container of the state storage account created
  # once by bootstrap-azure/, authenticated with Microsoft Entra ID (`az login`, no account keys)
  #   terraform init -backend-config=backend.hcl        (copy backend.hcl.example)
  # For local state instead, create backend_override.tf (git-ignored) with
  #   terraform { backend "local" {} }
  # See docs/terraform.md ("Runbook: first apply on Azure" and "Migrate from Cloudflare R2 to Azure Blob").
  backend "azurerm" {}
}
