output "instance_id" {
  description = "Azure resource id of the VM."
  value       = azurerm_linux_virtual_machine.app.id
}

output "resource_group_name" {
  description = "Resource group that holds every resource of the environment (deleting it deletes them all)."
  value       = azurerm_resource_group.this.name
}

output "location" {
  description = "Azure region of the resources."
  value       = azurerm_resource_group.this.location
}

output "vm_size" {
  description = "Size of the VM."
  value       = azurerm_linux_virtual_machine.app.size
}

output "public_ip" {
  description = "Static public IPv4 address of the VM (target of the DNS A record)."
  value       = local.public_ip
}

output "app_hostname" {
  description = "Hostname Caddy requests a Let's Encrypt certificate for."
  value       = local.app_hostname
}

output "app_url" {
  description = "Public HTTPS URL of the API."
  value       = "https://${local.app_hostname}"
}

output "dns_record" {
  description = "A record to create by hand at the DNS provider before the first deploy (empty when app_hostname is empty and sslip.io is used)."
  value       = var.app_hostname != "" ? "${var.app_hostname}. 300 IN A ${local.public_ip}" : ""
}

output "live_view_publish_url_template" {
  description = "Where agents publish live view (API TT_VIVO_URL_PUBLICACION)."
  value       = "rtsps://${local.app_hostname}:${var.live_view_publish_port}/camaras/{camaraId}"
}

output "live_view_hls_base_url" {
  description = "Base of the LL-HLS URLs the app plays, served by Caddy (API TT_VIVO_URL_HLS)."
  value       = "https://${local.app_hostname}/vivo"
}

output "live_view_webrtc_url_template" {
  description = "WebRTC (WHEP) endpoint of a camera, served by Caddy at /vivo-webrtc (API TT_VIVO_URL_WEBRTC); the media goes over live_view_webrtc_port."
  value       = "https://${local.app_hostname}/vivo-webrtc/camaras/{camaraId}/whep"
}

output "image" {
  description = "Marketplace image of the VM (publisher:offer:sku:version)."
  value       = join(":", [local.image.publisher, local.image.offer, local.image.sku, local.image.version])
}

output "memory_profile" {
  description = "Memory profile Ansible applies (tiny, micro, small, medium or large)."
  value       = local.memory_profile
}

output "instance_architecture" {
  description = "CPU architecture of the VM; images must be built for linux/<this>."
  value       = local.instance_architecture
}

output "ssh_command" {
  description = "SSH to the host (from admin_cidrs, with the private half of ssh_public_key)."
  value       = "ssh ${var.admin_username}@${local.public_ip}"
}

output "budget_id" {
  description = "Id of the monthly budget, or null without budget_alert_email."
  value       = one(azurerm_consumption_budget_subscription.monthly[*].id)
}

output "storage_account_name" {
  description = "Name of the storage account (API TT_AZURE_STORAGE_CUENTA)."
  value       = azurerm_storage_account.this.name
}

output "storage_account_id" {
  description = "Azure resource id of the storage account (scope of the role assignments)."
  value       = azurerm_storage_account.this.id
}

output "storage_blob_endpoint" {
  description = "Blob service endpoint, https://<account>.blob.core.windows.net (API TT_AZURE_STORAGE_ENDPOINT; also the host of the SAS URLs)."
  value       = trimsuffix(azurerm_storage_account.this.primary_blob_endpoint, "/")
}

output "clips_container_name" {
  description = "Private container of the clips, their landmarks and the profile photos (API TT_CLIPS_CONTENEDOR)."
  value       = azurerm_storage_container.this["clips"].name
}

output "movements_container_name" {
  description = "Private container of the movement files (API TT_MOVIMIENTOS_CONTENEDOR)."
  value       = azurerm_storage_container.this["movements"].name
}

output "backups_container_name" {
  description = "Private container of the database dumps (backup role)."
  value       = azurerm_storage_container.this["backups"].name
}

output "vm_principal_id" {
  description = "Object id of the VM's system-assigned managed identity (the role assignments' principal)."
  value       = azurerm_linux_virtual_machine.app.identity[0].principal_id
}

output "ansible_inventory" {
  description = "Ansible inventory of the host; write it with `make inventory ENV_DIR=envs/azure`."
  value = templatefile("${path.module}/templates/inventory.yml.tftpl", {
    host_alias             = local.name
    ansible_host           = local.public_ip
    ansible_user           = var.admin_username
    app_hostname           = local.app_hostname
    public_ip              = local.public_ip
    cloud_region           = var.location
    memory_profile         = local.memory_profile
    instance_architecture  = local.instance_architecture
    azure_storage_endpoint = trimsuffix(azurerm_storage_account.this.primary_blob_endpoint, "/")
    azure_storage_account  = azurerm_storage_account.this.name
    clips_container        = azurerm_storage_container.this["clips"].name
    movements_container    = azurerm_storage_container.this["movements"].name
    backups_container      = azurerm_storage_container.this["backups"].name
    live_view_publish_port = var.live_view_publish_port
    live_view_webrtc_port  = var.live_view_webrtc_port
  })
}
