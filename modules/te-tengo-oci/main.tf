data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_ocid
}

# Newest Canonical Ubuntu 24.04 platform image that runs on the shape. The display-name filter
# keeps the full image (not "Minimal") of the shape's architecture:
#   Canonical-Ubuntu-24.04-aarch64-<date>-<n>   (Ampere A1)
#   Canonical-Ubuntu-24.04-<date>-<n>           (x86)
data "oci_core_images" "ubuntu" {
  count = var.image_ocid == null ? 1 : 0

  compartment_id           = var.tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.shape
  state                    = "AVAILABLE"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  filter {
    name   = "display_name"
    values = [local.arm ? "^Canonical-Ubuntu-24\\.04-aarch64-[0-9]" : "^Canonical-Ubuntu-24\\.04-[0-9]"]
    regex  = true
  }
}

locals {
  name           = "${var.project}-${var.environment}"
  compartment_id = coalesce(var.compartment_ocid, var.tenancy_ocid)

  freeform_tags = merge({
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "Te-Tengo-Tech/te-tengo-infra"
  }, var.freeform_tags)

  # Ampere shapes (A1, A2...) are arm64.
  arm                   = startswith(var.shape, "VM.Standard.A")
  instance_architecture = local.arm ? "arm64" : "amd64"
  flex                  = endswith(var.shape, ".Flex")

  availability_domain = data.oci_identity_availability_domains.this.availability_domains[var.availability_domain_number - 1].name
  image_id            = var.image_ocid != null ? var.image_ocid : data.oci_core_images.ubuntu[0].images[0].id

  memory_profile = coalesce(var.memory_profile, (
    var.memory_in_gbs >= 6 ? "large" :
    var.memory_in_gbs >= 4 ? "medium" :
    var.memory_in_gbs >= 2 ? "small" : "micro"
  ))

  public_ip      = var.public_ip_mode == "reserved" ? oci_core_public_ip.reserved[0].ip_address : oci_core_instance.app.public_ip
  sslip_hostname = "${replace(local.public_ip, ".", "-")}.sslip.io"
  app_hostname   = var.app_hostname != "" ? var.app_hostname : local.sslip_hostname

  # Always Free allowance of the A1 shape and of block storage (docs/terraform.md, "Cost").
  always_free_a1_ocpus      = 2
  always_free_a1_memory_gbs = 12
  always_free_block_gbs     = 200
}

# A warning, not an error: a paid tenancy may choose a bigger host on purpose. The allowance is per
# tenancy: with the default 1 OCPU / 6 GB, the other half is left for a second VM.
check "always_free_allowance" {
  assert {
    condition = var.shape != "VM.Standard.A1.Flex" || (
      var.ocpus <= local.always_free_a1_ocpus &&
      var.memory_in_gbs <= local.always_free_a1_memory_gbs &&
      var.boot_volume_size_in_gbs <= local.always_free_block_gbs
    )
    error_message = "The host exceeds the Always Free allowance (2 OCPUs, 12 GB, 200 GB of volumes per tenancy): it will be billed on a paid account and cannot be created on a Free Tier one."
  }
}
