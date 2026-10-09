output "instance_id" {
  description = "OCID of the instance."
  value       = oci_core_instance.app.id
}

output "public_ip" {
  description = "Public IPv4 address of the instance (target of the DNS A record)."
  value       = local.public_ip
}

output "public_ip_mode" {
  description = "'ephemeral' or 'reserved'."
  value       = var.public_ip_mode
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

output "availability_domain" {
  description = "Availability domain of the instance."
  value       = local.availability_domain
}

output "image_id" {
  description = "Image the instance was created from (later image releases are ignored)."
  value       = oci_core_instance.app.source_details[0].source_id
}

output "memory_profile" {
  description = "Memory profile Ansible applies (micro, small, medium or large)."
  value       = local.memory_profile
}

output "instance_architecture" {
  description = "CPU architecture of the instance; images must be built for linux/<this>."
  value       = local.instance_architecture
}

output "ssh_command" {
  description = "SSH to the host (only from admin_cidrs, with the private half of ssh_public_key)."
  value       = "ssh ubuntu@${local.public_ip}"
}

output "ansible_inventory" {
  description = "Ansible inventory of the host; write it with `make inventory ENV_DIR=envs/oci`."
  value = templatefile("${path.module}/templates/inventory.yml.tftpl", {
    host_alias                = local.name
    ansible_host              = local.public_ip
    app_hostname              = local.app_hostname
    public_ip                 = local.public_ip
    cloud_region              = var.region
    memory_profile            = local.memory_profile
    instance_architecture     = local.instance_architecture
    object_storage_endpoint   = trimsuffix(var.object_storage_endpoint, "/")
    object_storage_region     = var.object_storage_region
    object_storage_path_style = var.object_storage_path_style
    clips_s3_bucket           = var.clips_bucket_name
    backup_s3_bucket          = var.backups_bucket_name
    live_view_publish_port    = var.live_view_publish_port
    live_view_webrtc_port     = var.live_view_webrtc_port
  })
}
