# ACTIVE environment: production on Microsoft Azure (Azure for Students subscription), one small Linux
# VM and one storage account (clips, movement files, database dumps) reached with the VM's managed
# identity. DNS is managed by hand at the registrar. Runbook: docs/terraform.md and docs/deploy.md.
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

  storage_account_suffix        = var.storage_account_suffix
  storage_cors_allowed_origins  = var.storage_cors_allowed_origins
  backups_retention_days        = var.backups_retention_days
  clips_retention_days          = var.clips_retention_days
  grant_operator_storage_access = var.grant_operator_storage_access

  budget_alert_email = var.budget_alert_email
  budget_amount      = var.budget_amount
}
