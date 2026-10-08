locals {
  name = "${var.project}-${var.environment}"

  tags = merge({
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "Te-Tengo-Tech/te-tengo-infra"
  }, var.tags)

  # Azure size names: Standard_<family><vCPUs><feature letters>[_v<n>]. A 'p' among the feature letters
  # marks an Arm64 (Ampere or Cobalt) size: Standard_B2pts_v2, Standard_D2ps_v5, Standard_D2pls_v6.
  vm_size_features      = regex("^Standard_[A-Z]+[0-9]+(?:-[0-9]+)?([a-z]*)", var.vm_size)[0]
  derived_architecture  = strcontains(local.vm_size_features, "p") ? "arm64" : "amd64"
  instance_architecture = coalesce(var.instance_architecture, local.derived_architecture)

  # Canonical Ubuntu 24.04 LTS, generation 2 image of the VM's architecture.
  image = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = local.instance_architecture == "arm64" ? "server-arm64" : "server"
    version   = "latest"
  }

  # Memory (GiB) of the sizes this project considers, from Microsoft's size pages (B-series v1 and v2).
  # Another size needs var.memory_profile.
  vm_size_memory_gib = {
    Standard_B1ls     = 0.5
    Standard_B1s      = 1
    Standard_B1ms     = 2
    Standard_B2s      = 4
    Standard_B2ms     = 8
    Standard_B2ats_v2 = 1
    Standard_B2ts_v2  = 1
    Standard_B2als_v2 = 4
    Standard_B2ls_v2  = 4
    Standard_B2as_v2  = 8
    Standard_B2pts_v2 = 1
    Standard_B2pls_v2 = 4
    Standard_B2ps_v2  = 8
    Standard_B4als_v2 = 8
    Standard_B4pls_v2 = 8
  }
  vm_memory_gib = lookup(local.vm_size_memory_gib, var.vm_size, null)

  # tiny: 1 GiB (the free B2ats_v2, B2pts_v2, B1s), small: 2 GiB (B1ms), medium: 4 GiB (B2als_v2, the
  # upgrade path in chilecentral), large: 6 GiB or more.
  derived_memory_profile = local.vm_memory_gib == null ? null : (
    local.vm_memory_gib >= 6 ? "large" :
    local.vm_memory_gib >= 4 ? "medium" :
    local.vm_memory_gib >= 2 ? "small" : "tiny"
  )
  memory_profile = var.memory_profile != null ? var.memory_profile : local.derived_memory_profile

  public_ip      = azurerm_public_ip.app.ip_address
  sslip_hostname = "${replace(local.public_ip, ".", "-")}.sslip.io"
  app_hostname   = var.app_hostname != "" ? var.app_hostname : local.sslip_hostname
}

resource "azurerm_resource_group" "this" {
  name     = "${local.name}-rg"
  location = var.location
  tags     = local.tags

  lifecycle {
    precondition {
      condition     = local.memory_profile != null
      error_message = "The module does not know the memory of ${var.vm_size}: set memory_profile (tiny, small, medium or large)."
    }
  }
}
