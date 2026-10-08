output "instance_id" {
  description = "EC2 instance id (target of SSM Session Manager)."
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "Elastic IP of the instance."
  value       = aws_eip.app.public_ip
}

output "app_hostname" {
  description = "Hostname Caddy requests a Let's Encrypt certificate for."
  value       = local.app_hostname
}

output "app_url" {
  description = "Public HTTPS URL of the API."
  value       = "https://${local.app_hostname}"
}

output "live_view_publish_url_template" {
  description = "Where agents publish live view (API TT_VIVO_URL_PUBLICACION)."
  value       = "rtsps://${local.app_hostname}:${var.live_view_publish_port}/camaras/{camaraId}"
}

output "live_view_hls_base_url" {
  description = "Base of the LL-HLS URLs the app plays, served by Caddy (API TT_VIVO_URL_HLS)."
  value       = "https://${local.app_hostname}/vivo"
}

output "clips_bucket" {
  description = "Private S3 bucket of the fall clips (API TT_CLIPS_BUCKET)."
  value       = aws_s3_bucket.this["clips"].id
}

output "backups_bucket" {
  description = "Private S3 bucket of the database dumps."
  value       = aws_s3_bucket.this["backups"].id
}

output "ses_sender" {
  description = "Sender of the API e-mails (API TT_SES_REMITENTE); empty when SES is off."
  value       = local.ses_sender
}

output "ses_identity_arns" {
  description = "SES identities the instance role may send from."
  value       = local.ses_identity_arns
}

output "ses_dkim_records" {
  description = "DKIM CNAME records of ses_domain (name => value), to add at the DNS provider when the domain is not in Route53."
  value = local.ses_domain_identity ? {
    for token in aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens :
    "${token}._domainkey.${var.ses_domain}" => "${token}.dkim.amazonses.com"
  } : {}
}

output "push_provider" {
  description = "Push provider the API should use (API TT_PUSH_PROVEEDOR): 'sns' when enable_sns, 'fcm' otherwise."
  value       = var.enable_sns ? "sns" : "fcm"
}

output "sns_platform_application_arn" {
  description = "SNS GCM platform application for Android and iOS (API TT_SNS_ARN_ANDROID and TT_SNS_ARN_IOS); empty when enable_sns is false."
  value       = var.enable_sns ? aws_sns_platform_application.fcm[0].arn : ""
}

output "instance_role_arn" {
  description = "IAM role of the instance."
  value       = aws_iam_role.app.arn
}

output "memory_profile" {
  description = "Memory profile Ansible applies ('small' with 2 GiB or more, 'micro' otherwise)."
  value       = local.memory_profile
}

output "instance_architecture" {
  description = "CPU architecture of the instance; images must be built for linux/<this>."
  value       = local.ami_architecture
}

output "instance_free_tier_eligible" {
  description = "Whether AWS flags instance_type as Free Tier eligible for the account running the plan (null when instance_type_facts is set)."
  value       = one(data.aws_ec2_instance_type.selected[*].free_tier_eligible)
}

output "ssm_session_command" {
  description = "Shell on the host through SSM Session Manager (no SSH key, no open port)."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.app.id}"
}

output "ssh_command" {
  description = "SSH tunnelled through SSM (needs ssh_public_key and the matching private key)."
  value = join(" ", [
    "ssh -o ProxyCommand=\"aws ssm start-session --region ${var.aws_region} --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p\"",
    "ubuntu@${aws_instance.app.id}",
  ])
}

output "github_deploy_role_arn" {
  description = "Role the GitHub deploy workflow assumes (variable AWS_DEPLOY_ROLE_ARN of the GitHub environment)."
  value       = one(aws_iam_role.github_deploy[*].arn)
}

output "ansible_inventory" {
  description = "Ansible inventory of the host; write it with `make inventory`."
  value = templatefile("${path.module}/templates/inventory.yml.tftpl", {
    host_alias                   = local.name
    ansible_host                 = var.inventory_transport == "ssm" ? aws_instance.app.id : aws_eip.app.public_ip
    use_ssm                      = var.inventory_transport == "ssm"
    app_hostname                 = local.app_hostname
    public_ip                    = aws_eip.app.public_ip
    aws_region                   = var.aws_region
    memory_profile               = local.memory_profile
    instance_architecture        = local.ami_architecture
    clips_s3_bucket              = aws_s3_bucket.this["clips"].id
    backup_s3_bucket             = aws_s3_bucket.this["backups"].id
    ses_sender                   = local.ses_sender
    push_provider                = var.enable_sns ? "sns" : "fcm"
    sns_platform_application_arn = var.enable_sns ? aws_sns_platform_application.fcm[0].arn : ""
    live_view_publish_port       = var.live_view_publish_port
  })
}
