resource "oci_core_instance" "app" {
  # checkov:skip=CKV_OCI_4:In-transit encryption is on through the top-level is_pv_encryption_in_transit_enabled; the check only reads the deprecated launch_options field.
  compartment_id      = local.compartment_id
  availability_domain = local.availability_domain
  display_name        = local.name
  shape               = var.shape
  freeform_tags       = local.freeform_tags

  # Encrypt the paravirtualized boot volume traffic between the host and the storage service
  # (the volume itself is always encrypted at rest with an Oracle-managed key).
  is_pv_encryption_in_transit_enabled = true

  dynamic "shape_config" {
    for_each = local.flex ? [1] : []

    content {
      ocpus         = var.ocpus
      memory_in_gbs = var.memory_in_gbs
    }
  }

  source_details {
    source_type             = "image"
    source_id               = local.image_id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  create_vnic_details {
    subnet_id      = oci_core_subnet.public.id
    display_name   = local.name
    hostname_label = "app"
    # With a reserved public IP the VNIC starts without one: OCI only assigns a reserved IP to a
    # private IP that has no public IP yet.
    assign_public_ip = var.public_ip_mode == "ephemeral"
  }

  metadata = {
    ssh_authorized_keys = trimspace(var.ssh_public_key)
    user_data           = base64encode(file("${path.module}/templates/cloud-init.yaml"))
  }

  # Instance metadata only through the v2 endpoints (token-less IMDSv1 paths are off).
  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  agent_config {
    is_monitoring_disabled = false
    is_management_disabled = false
  }

  availability_config {
    recovery_action = "RESTORE_INSTANCE"
  }

  lifecycle {
    # A newer Ubuntu image or a cloud-init change must not replace the host (and its database).
    ignore_changes = [source_details[0].source_id, metadata["user_data"]]
  }
}

data "oci_core_vnic_attachments" "app" {
  count = var.public_ip_mode == "reserved" ? 1 : 0

  compartment_id = local.compartment_id
  instance_id    = oci_core_instance.app.id
}

data "oci_core_private_ips" "app" {
  count = var.public_ip_mode == "reserved" ? 1 : 0

  vnic_id = data.oci_core_vnic_attachments.app[0].vnic_attachments[0].vnic_id
}

resource "oci_core_public_ip" "reserved" {
  count = var.public_ip_mode == "reserved" ? 1 : 0

  compartment_id = local.compartment_id
  display_name   = local.name
  lifetime       = "RESERVED"
  private_ip_id  = data.oci_core_private_ips.app[0].private_ips[0].id
  freeform_tags  = local.freeform_tags
}
