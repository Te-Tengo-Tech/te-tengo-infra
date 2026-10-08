output "instance_id" {
  description = "EC2 instance id (target of SSM Session Manager)."
  value       = module.te_tengo.instance_id
}

output "public_ip" {
  description = "Elastic IP of the instance."
  value       = module.te_tengo.public_ip
}

output "app_hostname" {
  description = "Hostname Caddy requests a Let's Encrypt certificate for."
  value       = module.te_tengo.app_hostname
}

output "app_url" {
  description = "Public HTTPS URL of the API."
  value       = module.te_tengo.app_url
}

output "live_view_publish_url_template" {
  description = "Where agents publish live view (API TT_VIVO_URL_PUBLICACION)."
  value       = module.te_tengo.live_view_publish_url_template
}

output "live_view_hls_base_url" {
  description = "Base of the LL-HLS URLs the app plays, served by Caddy (API TT_VIVO_URL_HLS)."
  value       = module.te_tengo.live_view_hls_base_url
}

output "clips_bucket" {
  description = "Private S3 bucket of the fall clips (API TT_CLIPS_BUCKET)."
  value       = module.te_tengo.clips_bucket
}

output "backups_bucket" {
  description = "Private S3 bucket of the database dumps."
  value       = module.te_tengo.backups_bucket
}

output "ses_sender" {
  description = "Sender of the API e-mails (API TT_SES_REMITENTE); empty when SES is off."
  value       = module.te_tengo.ses_sender
}

output "ses_identity_arns" {
  description = "SES identities the instance role may send from."
  value       = module.te_tengo.ses_identity_arns
}

output "ses_dkim_records" {
  description = "DKIM CNAME records of ses_domain (name => value), to add at the DNS provider when the domain is not in Route53."
  value       = module.te_tengo.ses_dkim_records
}

output "push_provider" {
  description = "Push provider the API should use (API TT_PUSH_PROVEEDOR): 'sns' when enable_sns, 'fcm' otherwise."
  value       = module.te_tengo.push_provider
}

output "sns_platform_application_arn" {
  description = "SNS GCM platform application for Android and iOS (API TT_SNS_ARN_ANDROID and TT_SNS_ARN_IOS); empty when enable_sns is false."
  value       = module.te_tengo.sns_platform_application_arn
}

output "instance_role_arn" {
  description = "IAM role of the instance."
  value       = module.te_tengo.instance_role_arn
}

output "memory_profile" {
  description = "Memory profile Ansible applies ('small' with 2 GiB or more, 'micro' otherwise)."
  value       = module.te_tengo.memory_profile
}

output "instance_architecture" {
  description = "CPU architecture of the instance; images must be built for linux/<this>."
  value       = module.te_tengo.instance_architecture
}

output "instance_free_tier_eligible" {
  description = "Whether AWS flags instance_type as Free Tier eligible for the account running the plan."
  value       = module.te_tengo.instance_free_tier_eligible
}

output "ssm_session_command" {
  description = "Shell on the host through SSM Session Manager (no SSH key, no open port)."
  value       = module.te_tengo.ssm_session_command
}

output "ssh_command" {
  description = "SSH tunnelled through SSM (needs ssh_public_key and the matching private key)."
  value       = module.te_tengo.ssh_command
}

output "github_deploy_role_arn" {
  description = "Role the GitHub deploy workflow assumes (variable AWS_DEPLOY_ROLE_ARN of the GitHub environment)."
  value       = module.te_tengo.github_deploy_role_arn
}

output "ansible_inventory" {
  description = "Ansible inventory of the host; write it with `make inventory`."
  value       = module.te_tengo.ansible_inventory
}
