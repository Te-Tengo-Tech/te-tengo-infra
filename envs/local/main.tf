# A hosted zone inside the emulator, so the Route53 code paths (app A record, SES DKIM CNAMEs)
# run too. In envs/mvp the zone must already exist and is only read.
resource "aws_route53_zone" "local" {
  count = var.enable_route53 ? 1 : 0

  # checkov:skip=CKV2_AWS_38:Emulator-only zone; DNSSEC is not applicable.
  # checkov:skip=CKV2_AWS_39:Emulator-only zone; query logging is not applicable.
  name          = "tetengo.test"
  force_destroy = true
}

module "te_tengo" {
  source = "../../modules/te-tengo"

  environment = "local"
  aws_region  = var.aws_region

  instance_type = "t4g.small"

  # Floci 2.2.0 answers DescribeInstanceTypes, but the provider's aws_ec2_instance_type data
  # source finds no match in its response, so the facts of t4g.small are given here.
  instance_type_facts = {
    architectures = ["arm64"]
    memory_mib    = 2048
    burstable     = true
  }

  termination_protection = false
  # Exercises the key-pair code path; the private half was discarded when it was generated.
  ssh_public_key        = trimspace(file("${path.module}/throwaway_ed25519.pub"))
  inventory_transport   = "direct"
  force_destroy_buckets = true

  # The zone name is known at plan time; depends_on defers the module's zone lookup until the
  # zone exists.
  dns_zone_name   = var.enable_route53 ? "tetengo.test" : ""
  dns_record_name = "mvp"

  clips_retention_days       = 30
  clips_cors_allowed_origins = ["http://localhost:8080"]

  enable_ses       = var.enable_ses
  ses_sender_email = "no-responder@tetengo.test"
  ses_domain       = "tetengo.test"

  enable_sns                   = var.enable_sns
  sns_fcm_service_account_json = jsonencode({ type = "service_account", project_id = "te-tengo-local" })

  github_deploy_repository = var.enable_github_deploy ? "Te-Tengo-Tech/te-tengo-infra" : ""

  depends_on = [aws_route53_zone.local]
}
