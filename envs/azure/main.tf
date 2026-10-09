# ACTIVE environment: production on Microsoft Azure (Azure for Students subscription), one small Linux
# VM. Object storage is Cloudflare R2 and DNS is managed by hand at the registrar, so the only cloud
# resources are the network, the public IP and the VM. Runbook: docs/terraform.md and docs/deploy.md.
module "te_tengo" {
  source = "../../modules/te-tengo-azure"

  environment = var.environment
  location    = var.location

  vm_size                      = var.vm_size
  memory_profile               = var.memory_profile
  admin_username               = var.admin_username
  ssh_public_key               = var.ssh_public_key
  os_disk_storage_account_type = var.os_disk_storage_account_type
  os_disk_size_gb              = var.os_disk_size_gb

  admin_cidrs  = var.admin_cidrs
  app_hostname = var.app_hostname

  object_storage_endpoint = var.object_storage_endpoint
  object_storage_region   = var.object_storage_region
  clips_bucket_name       = var.clips_bucket_name
  backups_bucket_name     = var.backups_bucket_name

  budget_alert_email = var.budget_alert_email
  budget_amount      = var.budget_amount
}
