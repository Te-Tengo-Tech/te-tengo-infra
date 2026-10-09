# ACTIVE environment: production on Oracle Cloud Infrastructure Always Free (one Ampere A1 VM).
# Object storage is Cloudflare R2 and DNS is managed by hand at the registrar, so the only cloud
# resources are the network and the VM. Runbook: docs/terraform.md and docs/deploy.md.
module "te_tengo" {
  source = "../../modules/te-tengo-oci"

  environment      = var.environment
  region           = var.region
  tenancy_ocid     = var.tenancy_ocid
  compartment_ocid = var.compartment_ocid

  shape                      = var.shape
  ocpus                      = var.ocpus
  memory_in_gbs              = var.memory_in_gbs
  boot_volume_size_in_gbs    = var.boot_volume_size_in_gbs
  availability_domain_number = var.availability_domain_number
  image_ocid                 = var.image_ocid
  ssh_public_key             = var.ssh_public_key

  admin_cidrs    = var.admin_cidrs
  public_ip_mode = var.public_ip_mode
  app_hostname   = var.app_hostname

  object_storage_endpoint = var.object_storage_endpoint
  object_storage_region   = var.object_storage_region
  clips_bucket_name       = var.clips_bucket_name
  backups_bucket_name     = var.backups_bucket_name
}
