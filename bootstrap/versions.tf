terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # bootstrap/ creates the remote backend, so its own state is local (git-ignored). Back it up.
  backend "local" {}
}
