terraform {
  required_version = ">= 1.10.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
  }

  # Partial configuration: the state goes to a private Cloudflare R2 bucket through the S3 backend
  #   terraform init -backend-config=backend.hcl        (copy backend.hcl.example)
  # For local state instead, create backend_override.tf (git-ignored) with
  #   terraform { backend "local" {} }
  # See docs/terraform.md ("Runbook: first apply on Azure").
  backend "s3" {}
}
