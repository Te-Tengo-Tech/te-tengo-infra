terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial configuration: the bucket comes from bootstrap/ and is passed at init time with
  #   terraform init -backend-config=backend.hcl
  # (copy backend.hcl.example). use_lockfile locks the state with an S3 object, no DynamoDB.
  backend "s3" {}
}
