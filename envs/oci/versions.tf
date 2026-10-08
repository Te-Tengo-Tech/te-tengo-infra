terraform {
  required_version = ">= 1.10.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.8"
    }
  }

  # Partial configuration: the state goes to a private Cloudflare R2 bucket through the S3 backend
  #   terraform init -backend-config=backend.hcl        (copy backend.hcl.example)
  # For local state instead, create backend_override.tf (git-ignored) with
  #   terraform { backend "local" {} }
  # See docs/terraform.md ("State").
  backend "s3" {}
}
