# Same module as envs/mvp, pointed at the Floci AWS emulator (floci/floci, `make local-up`).
# Nothing here can reach a real AWS account: every service the module calls has an endpoint
# override (STS included) and the keys are Floci's built-in test/test pair.
provider "aws" {
  # checkov:skip=CKV_AWS_41:test/test are the Floci emulator's documented dummy keys, not AWS credentials.
  region     = var.aws_region
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  # Must stay false: the provider builds some ARNs itself (SESv2 identities, EC2 instances) from
  # the account id, and with true they come out as arn:aws:ses:us-east-1::identity/..., which
  # Floci rejects (ListTagsForResource 400) and which crashed Terraform 1.16 while saving state.
  # The lookup is sts:GetCallerIdentity against the sts endpoint below, i.e. Floci (000000000000).
  skip_requesting_account_id = false
  skip_metadata_api_check    = true
  skip_region_validation     = true
  s3_use_path_style          = true

  endpoints {
    ec2       = var.floci_endpoint
    iam       = var.floci_endpoint
    route53   = var.floci_endpoint
    s3        = var.floci_endpoint
    s3control = var.floci_endpoint
    ses       = var.floci_endpoint
    sesv2     = var.floci_endpoint
    sns       = var.floci_endpoint
    ssm       = var.floci_endpoint
    sts       = var.floci_endpoint
  }

  default_tags {
    tags = {
      Project     = "te-tengo"
      Environment = "local"
      ManagedBy   = "terraform"
      Repository  = "Te-Tengo-Tech/te-tengo-infra"
    }
  }
}
