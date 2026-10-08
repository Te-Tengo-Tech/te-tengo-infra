provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "te-tengo"
      Environment = "shared"
      ManagedBy   = "terraform"
      Repository  = "Te-Tengo-Tech/te-tengo-infra"
    }
  }
}
