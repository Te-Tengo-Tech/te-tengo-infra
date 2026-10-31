terraform {
  required_version = ">= 1.10.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
  }

  # Local state on purpose: this configuration creates the account that holds every other state, so it
  # cannot keep its own state there. Its state only describes four resources; keep a copy of
  # terraform.tfstate in the team's password manager (docs/terraform.md, "Remote state on Azure").
}
