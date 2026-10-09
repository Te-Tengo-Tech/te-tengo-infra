output "instance_id" {
  description = "Azure resource id of the VM."
  value       = module.te_tengo.instance_id
}

output "resource_group_name" {
  description = "Resource group of the environment."
  value       = module.te_tengo.resource_group_name
}

output "location" {
  description = "Azure region of the resources."
  value       = module.te_tengo.location
}

output "vm_size" {
  description = "Size of the VM."
  value       = module.te_tengo.vm_size
}

output "public_ip" {
  description = "Static public IPv4 address of the VM (target of the DNS A record)."
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

output "dns_record" {
  description = "A record to create by hand at the DNS provider (Namify) before the first deploy."
  value       = module.te_tengo.dns_record
}

output "live_view_publish_url_template" {
  description = "Where agents publish live view (API TT_VIVO_URL_PUBLICACION)."
  value       = module.te_tengo.live_view_publish_url_template
}

output "live_view_hls_base_url" {
  description = "Base of the LL-HLS URLs the app plays, served by Caddy (API TT_VIVO_URL_HLS)."
  value       = module.te_tengo.live_view_hls_base_url
}

output "image" {
  description = "Marketplace image of the VM."
  value       = module.te_tengo.image
}

output "memory_profile" {
  description = "Memory profile Ansible applies."
  value       = module.te_tengo.memory_profile
}

output "instance_architecture" {
  description = "CPU architecture of the VM; images must be built for linux/<this>."
  value       = module.te_tengo.instance_architecture
}

output "ssh_command" {
  description = "SSH to the host (from admin_cidrs)."
  value       = module.te_tengo.ssh_command
}

output "budget_id" {
  description = "Id of the monthly budget, or null without budget_alert_email."
  value       = module.te_tengo.budget_id
}

output "ansible_inventory" {
  description = "Ansible inventory of the host; write it with `make inventory` (envs/azure is the default)."
  value       = module.te_tengo.ansible_inventory
}
