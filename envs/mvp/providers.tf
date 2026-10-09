provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "te-tengo"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "Te-Tengo-Tech/te-tengo-infra"
    }
  }
}
