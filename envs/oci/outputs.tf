output "instance_id" {
  description = "OCID of the instance."
  value       = module.te_tengo.instance_id
}

output "public_ip" {
  description = "Public IPv4 address of the instance (target of the DNS A record)."
  value       = module.te_tengo.public_ip
}

output "public_ip_mode" {
  description = "'ephemeral' or 'reserved'."
  value       = module.te_tengo.public_ip_mode
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

output "availability_domain" {
  description = "Availability domain of the instance."
  value       = module.te_tengo.availability_domain
}

output "image_id" {
  description = "Image the instance was created from."
  value       = module.te_tengo.image_id
}

output "memory_profile" {
  description = "Memory profile Ansible applies."
  value       = module.te_tengo.memory_profile
}

output "instance_architecture" {
  description = "CPU architecture of the instance; images must be built for linux/<this>."
  value       = module.te_tengo.instance_architecture
}

output "ssh_command" {
  description = "SSH to the host (only from admin_cidrs)."
  value       = module.te_tengo.ssh_command
}

output "ansible_inventory" {
  description = "Ansible inventory of the host; write it with `make inventory ENV_DIR=envs/oci`."
  value       = module.te_tengo.ansible_inventory
}
