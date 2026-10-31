output "backend_config" {
  description = "Contents for envs/azure/backend.hcl (no secret: authentication is the operator's `az login`)."
  value       = <<-EOT
    resource_group_name  = "${azurerm_resource_group.state.name}"
    storage_account_name = "${azurerm_storage_account.state.name}"
    container_name       = "${azurerm_storage_container.tfstate.name}"
    key                  = "envs/azure/terraform.tfstate"
    use_azuread_auth     = true
    subscription_id      = "${var.subscription_id}"
  EOT
}

output "storage_account_id" {
  description = "Azure resource id of the state storage account (scope for another operator's role assignment)."
  value       = azurerm_storage_account.state.id
}
