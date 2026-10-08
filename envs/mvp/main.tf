# INACTIVE alternative: the same host on AWS (EC2 t4g.small). It is kept validated (and exercised
# against the Floci emulator through envs/local) but has never been applied; production runs on
# Oracle Cloud Always Free (envs/oci). By default it is "VM only": clips and backups live in
# Cloudflare R2, e-mail goes through an SMTP relay and DNS is managed at the registrar; S3, SES, SNS
# and Route53 can be switched back on with the enable_* / dns_zone_name variables.
module "te_tengo" {
  source = "../../modules/te-tengo"

  environment = var.environment
  aws_region  = var.aws_region

  instance_type          = var.instance_type
  root_volume_size       = var.root_volume_size
  cpu_credits            = var.cpu_credits
  termination_protection = var.termination_protection
  ssh_public_key         = var.ssh_public_key

  dns_zone_name   = var.dns_zone_name
  dns_record_name = var.dns_record_name
  app_hostname    = var.app_hostname

  enable_s3_buckets       = var.enable_s3_buckets
  object_storage_endpoint = var.object_storage_endpoint
  object_storage_region   = var.object_storage_region
  clips_bucket_name       = var.clips_bucket_name
  backups_bucket_name     = var.backups_bucket_name

  clips_retention_days       = var.clips_retention_days
  clips_cors_allowed_origins = var.clips_cors_allowed_origins
  backups_retention_days     = var.backups_retention_days

  enable_ses       = var.enable_ses
  ses_sender_email = var.ses_sender_email
  ses_sender_name  = var.ses_sender_name
  ses_domain       = var.ses_domain

  enable_sns                   = var.enable_sns
  sns_fcm_service_account_json = var.sns_fcm_service_account_json

  github_deploy_repository  = var.github_deploy_repository
  github_deploy_environment = var.github_deploy_environment
  github_oidc_provider_arn  = var.github_oidc_provider_arn
}
