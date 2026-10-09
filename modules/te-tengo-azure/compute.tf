resource "azurerm_linux_virtual_machine" "app" {
  # checkov:skip=CKV_AZURE_50:The VM agent's extension handling stays on so the portal's "Reset password" (VMAccess) can restore SSH access; no extension is installed by this module.
  name                = local.name
  computer_name       = local.name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  size                = var.vm_size
  tags                = local.tags

  network_interface_ids = [azurerm_network_interface.app.id]

  admin_username                  = var.admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = trimspace(var.ssh_public_key)
  }

  # Only what Ansible needs to take over (python3); docs/ansible.md.
  custom_data = base64encode(file("${path.module}/templates/cloud-init.yaml"))

  os_disk {
    name                 = "${local.name}-os"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_storage_account_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = local.image.publisher
    offer     = local.image.offer
    sku       = local.image.sku
    version   = local.image.version
  }

  # Trusted Launch (generation 2 image): Secure Boot and vTPM, no extra cost.
  secure_boot_enabled = var.trusted_launch
  vtpm_enabled        = var.trusted_launch

  # Serial log and screenshot in a Microsoft-managed storage account (no storage_account_uri), which
  # Microsoft does not bill; the serial log shows the SSH host key fingerprints for the first login.
  boot_diagnostics {}

  lifecycle {
    # A cloud-init change must not replace the host (and its database).
    ignore_changes = [custom_data]

    precondition {
      condition     = !(var.os_disk_storage_account_type == "Premium_LRS" && !strcontains(local.vm_size_features, "s"))
      error_message = "Premium_LRS needs a VM size with premium storage support (an 's' in its feature letters, e.g. Standard_B2ats_v2)."
    }
  }
}
