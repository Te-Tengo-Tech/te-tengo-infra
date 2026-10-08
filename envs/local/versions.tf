terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Emulator state is disposable: keep it next to the configuration (git-ignored).
  backend "local" {}
}
