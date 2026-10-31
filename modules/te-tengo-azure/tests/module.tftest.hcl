# Offline tests of the Azure module: the hashicorp/azurerm provider is mocked, so no subscription,
# credentials or network are needed (`make tf-test`). They check the module's own logic: image and
# architecture from the size, NSG rules, disk options, memory profile, the optional budget, the storage
# account (hardening, containers, lifecycle, CORS, role assignments of the VM's managed identity) and the
# rendered inventory.

# The provider checks the format of the resource ids passed between resources even when mocked, so
# every referenced resource gets a well-formed Azure id.
mock_provider "azurerm" {
  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/te-tengo-prod-rg"
    }
  }

  mock_resource "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/te-tengo-prod-rg/providers/Microsoft.Network/virtualNetworks/te-tengo-prod-vnet"
    }
  }

  mock_resource "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/te-tengo-prod-rg/providers/Microsoft.Network/virtualNetworks/te-tengo-prod-vnet/subnets/te-tengo-prod-app"
    }
  }

  mock_resource "azurerm_network_security_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/te-tengo-prod-rg/providers/Microsoft.Network/networkSecurityGroups/te-tengo-prod-app"
    }
  }

  mock_resource "azurerm_public_ip" {
    defaults = {
      id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/te-tengo-prod-rg/providers/Microsoft.Network/publicIPAddresses/te-tengo-prod-ip"
      ip_address = "192.0.2.10"
    }
  }

  mock_resource "azurerm_network_interface" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/te-tengo-prod-rg/providers/Microsoft.Network/networkInterfaces/te-tengo-prod-nic"
    }
  }

  mock_resource "azurerm_linux_virtual_machine" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/te-tengo-prod-rg/providers/Microsoft.Compute/virtualMachines/te-tengo-prod"
      identity = {
        principal_id = "11111111-1111-1111-1111-111111111111"
        tenant_id    = "22222222-2222-2222-2222-222222222222"
      }
    }
  }

  mock_resource "azurerm_storage_account" {
    defaults = {
      id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/te-tengo-prod-rg/providers/Microsoft.Storage/storageAccounts/tetengoproddata"
      primary_blob_endpoint = "https://tetengoproddata.blob.core.windows.net/"
    }
  }

  # Every container gets the same mocked id; the role assignment scopes only need a well-formed one.
  mock_resource "azurerm_storage_container" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/te-tengo-prod-rg/providers/Microsoft.Storage/storageAccounts/tetengoproddata/blobServices/default/containers/clips"
    }
  }

  mock_resource "azurerm_storage_management_policy" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/te-tengo-prod-rg/providers/Microsoft.Storage/storageAccounts/tetengoproddata/managementPolicies/default"
    }
  }

  mock_resource "azurerm_role_assignment" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/te-tengo-prod-rg/providers/Microsoft.Storage/storageAccounts/tetengoproddata/providers/Microsoft.Authorization/roleAssignments/33333333-3333-3333-3333-333333333333"
    }
  }

  mock_data "azurerm_client_config" {
    defaults = {
      object_id       = "44444444-4444-4444-4444-444444444444"
      tenant_id       = "22222222-2222-2222-2222-222222222222"
      subscription_id = "00000000-0000-0000-0000-000000000000"
      client_id       = "55555555-5555-5555-5555-555555555555"
    }
  }

  mock_resource "azurerm_consumption_budget_subscription" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Consumption/budgets/te-tengo-prod-monthly"
    }
  }

  mock_data "azurerm_subscription" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  location       = "chilecentral"
  ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDKOTofJNaBqkM4ZkD/bzKoT9rZ5KyoClpW+tUX3hW/V test"
  app_hostname   = "api.tetengo.reqsai.tech"
}

run "free_size_defaults" {
  command = apply

  assert {
    condition     = azurerm_linux_virtual_machine.app.size == "Standard_B2ats_v2" && azurerm_resource_group.this.location == "chilecentral"
    error_message = "The default host must be a Standard_B2ats_v2 in the chosen location."
  }

  assert {
    condition = (
      azurerm_linux_virtual_machine.app.source_image_reference[0].publisher == "Canonical" &&
      azurerm_linux_virtual_machine.app.source_image_reference[0].offer == "ubuntu-24_04-lts" &&
      azurerm_linux_virtual_machine.app.source_image_reference[0].sku == "server" &&
      azurerm_linux_virtual_machine.app.source_image_reference[0].version == "latest"
    )
    error_message = "An x64 size must boot Canonical Ubuntu 24.04 LTS (sku server)."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.app.os_disk[0].storage_account_type == "StandardSSD_LRS" && azurerm_linux_virtual_machine.app.os_disk[0].disk_size_gb == 30
    error_message = "The default OS disk must be a 30 GB Standard SSD."
  }

  assert {
    condition = (
      azurerm_linux_virtual_machine.app.disable_password_authentication &&
      azurerm_linux_virtual_machine.app.admin_username == "ubuntu" &&
      one(azurerm_linux_virtual_machine.app.admin_ssh_key[*].username) == "ubuntu"
    )
    error_message = "SSH must use the key only (password authentication disabled) for the ubuntu user."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.app.secure_boot_enabled && azurerm_linux_virtual_machine.app.vtpm_enabled
    error_message = "Trusted Launch (Secure Boot and vTPM) must be on by default."
  }

  assert {
    condition     = length(azurerm_linux_virtual_machine.app.boot_diagnostics) == 1 && azurerm_linux_virtual_machine.app.boot_diagnostics[0].storage_account_uri == null
    error_message = "Boot diagnostics must use the managed storage account (no storage_account_uri)."
  }

  assert {
    condition     = azurerm_public_ip.app.sku == "Standard" && azurerm_public_ip.app.allocation_method == "Static" && azurerm_public_ip.app.ip_version == "IPv4"
    error_message = "The public IP must be a static Standard IPv4."
  }

  assert {
    condition     = output.public_ip == "192.0.2.10" && output.app_url == "https://api.tetengo.reqsai.tech" && output.ssh_command == "ssh ubuntu@192.0.2.10"
    error_message = "Public IP, URL and SSH command come from the static IP and app_hostname."
  }

  assert {
    condition     = output.dns_record == "api.tetengo.reqsai.tech. 300 IN A 192.0.2.10"
    error_message = "The DNS record to create by hand is wrong."
  }

  assert {
    condition     = output.memory_profile == "tiny" && output.instance_architecture == "amd64"
    error_message = "Standard_B2ats_v2 (1 GiB, AMD) must give the 'tiny' profile on amd64."
  }

  assert {
    condition     = output.budget_id == null && length(azurerm_consumption_budget_subscription.monthly) == 0
    error_message = "No budget may be created without budget_alert_email."
  }

  assert {
    condition     = azurerm_subnet_network_security_group_association.app.subnet_id == azurerm_subnet.app.id && azurerm_network_interface.app.ip_configuration[0].public_ip_address_id == azurerm_public_ip.app.id
    error_message = "The NSG must guard the VM's subnet and the NIC must carry the public IP."
  }
}

run "nsg_rules" {
  command = apply

  variables {
    admin_cidrs = ["203.0.113.7/32"]
  }

  # SSH only from admin_cidrs.
  assert {
    condition = toset(flatten([
      for rule in azurerm_network_security_group.app.security_rule : rule.source_address_prefixes
      if rule.destination_port_range == "22"
    ])) == toset(["203.0.113.7/32"])
    error_message = "SSH must be open only to admin_cidrs."
  }

  # Inbound allows: exactly 80/TCP, 443/TCP, 443/UDP, 8322/TCP and 8189/UDP+TCP (WebRTC) from anywhere,
  # plus SSH.
  assert {
    condition = toset([
      for rule in azurerm_network_security_group.app.security_rule : "${rule.protocol}/${rule.destination_port_range}"
      if rule.direction == "Inbound" && rule.access == "Allow" && contains(rule.source_address_prefixes, "0.0.0.0/0")
    ]) == toset(["Tcp/80", "Tcp/443", "Udp/443", "Tcp/8322", "Udp/8189", "Tcp/8189"])
    error_message = "Only 80/TCP, 443/TCP, 443/UDP, 8322/TCP and 8189/UDP+TCP may be open to the Internet."
  }

  assert {
    condition     = length(azurerm_network_security_group.app.security_rule) == 7 && alltrue([for rule in azurerm_network_security_group.app.security_rule : rule.direction == "Inbound" && rule.access == "Allow"])
    error_message = "The NSG must hold exactly the seven inbound allow rules (outbound keeps the defaults)."
  }
}

run "default_ssh_is_open_with_keys" {
  command = plan

  assert {
    condition = toset(flatten([
      for rule in azurerm_network_security_group.app.security_rule : rule.source_address_prefixes
      if rule.destination_port_range == "22"
    ])) == toset(["0.0.0.0/0"])
    error_message = "By default SSH is reachable from anywhere (WARP and GitHub-hosted runners), keys only."
  }
}

run "inventory_shape" {
  command = apply

  assert {
    condition = yamldecode(output.ansible_inventory).all.children.te_tengo.hosts["te-tengo-prod"] == {
      ansible_host                 = "192.0.2.10"
      ansible_user                 = "ubuntu"
      ansible_connection           = "ssh"
      app_hostname                 = "api.tetengo.reqsai.tech"
      public_ip                    = "192.0.2.10"
      cloud_provider               = "azure"
      cloud_region                 = "chilecentral"
      memory_profile               = "tiny"
      instance_architecture        = "amd64"
      object_storage_provider      = "azure"
      object_storage_auth          = "managed_identity"
      azure_storage_endpoint       = "https://tetengoproddata.blob.core.windows.net"
      azure_storage_account        = "tetengoproddata"
      clips_container              = "clips"
      movements_container          = "movements"
      backups_container            = "backups"
      ses_sender                   = ""
      push_provider                = "fcm"
      sns_platform_application_arn = ""
      live_view_publish_port       = 8322
      live_view_webrtc_port        = 8189
    }
    error_message = "The rendered inventory does not match docs/interface-terraform-ansible.md."
  }
}

run "arm_size_and_sslip" {
  command = apply

  variables {
    vm_size      = "Standard_B2pts_v2"
    app_hostname = ""
  }

  assert {
    condition     = azurerm_linux_virtual_machine.app.source_image_reference[0].sku == "server-arm64" && output.instance_architecture == "arm64"
    error_message = "An Arm size (a 'p' in its feature letters) must boot the server-arm64 image."
  }

  assert {
    condition     = output.app_hostname == "192-0-2-10.sslip.io" && output.dns_record == ""
    error_message = "Without app_hostname the static IP must give an sslip.io name."
  }

  assert {
    condition     = output.memory_profile == "tiny"
    error_message = "Standard_B2pts_v2 (1 GiB) must give the 'tiny' profile."
  }
}

run "memory_profiles_follow_the_size" {
  command = plan

  variables {
    vm_size = "Standard_B1ms"
  }

  assert {
    condition     = output.memory_profile == "small" && output.instance_architecture == "amd64"
    error_message = "Standard_B1ms (2 GiB) must give the 'small' profile."
  }
}

run "medium_and_large_profiles" {
  command = plan

  variables {
    vm_size = "Standard_B2als_v2"
  }

  assert {
    condition     = output.memory_profile == "medium"
    error_message = "A 4 GiB size must give the 'medium' profile."
  }
}

run "large_profile" {
  command = plan

  variables {
    vm_size = "Standard_B2ps_v2"
  }

  assert {
    condition     = output.memory_profile == "large" && output.instance_architecture == "arm64"
    error_message = "An 8 GiB Arm size must give the 'large' profile on arm64."
  }
}

run "premium_p6_disk" {
  command = plan

  variables {
    os_disk_storage_account_type = "Premium_LRS"
    os_disk_size_gb              = 64
  }

  assert {
    condition     = azurerm_linux_virtual_machine.app.os_disk[0].storage_account_type == "Premium_LRS" && azurerm_linux_virtual_machine.app.os_disk[0].disk_size_gb == 64
    error_message = "Premium_LRS with 64 GB must give a P6 OS disk."
  }
}

run "premium_needs_premium_capable_size" {
  command = plan

  variables {
    vm_size                      = "Standard_B2pts_v2"
    os_disk_storage_account_type = "Premium_LRS"
    os_disk_size_gb              = 64
    memory_profile               = "tiny"
  }

  # Standard_B2pts_v2 has an 's': this must pass. The negative case below uses a size without one.
  assert {
    condition     = azurerm_linux_virtual_machine.app.os_disk[0].storage_account_type == "Premium_LRS"
    error_message = "A size with an 's' accepts Premium_LRS."
  }
}

run "premium_rejected_without_s" {
  command = plan

  variables {
    vm_size                      = "Standard_A2_v2"
    memory_profile               = "medium"
    os_disk_storage_account_type = "Premium_LRS"
    os_disk_size_gb              = 64
  }

  expect_failures = [azurerm_linux_virtual_machine.app]
}

run "unknown_size_needs_a_profile" {
  command = plan

  variables {
    vm_size = "Standard_D2s_v5"
  }

  expect_failures = [azurerm_resource_group.this]
}

run "unknown_size_with_a_profile" {
  command = plan

  variables {
    vm_size        = "Standard_D2s_v5"
    memory_profile = "large"
  }

  assert {
    condition     = output.memory_profile == "large" && output.instance_architecture == "amd64"
    error_message = "An explicit memory_profile must be used for sizes the module does not know."
  }
}

run "budget_when_requested" {
  command = apply

  variables {
    budget_alert_email = "ops@example.com"
    budget_start_date  = "2026-10-01T00:00:00Z"
  }

  assert {
    condition     = azurerm_consumption_budget_subscription.monthly[0].amount == 5 && azurerm_consumption_budget_subscription.monthly[0].time_grain == "Monthly"
    error_message = "The budget must be USD 5 a month."
  }

  assert {
    condition = toset([
      for n in azurerm_consumption_budget_subscription.monthly[0].notification : "${n.threshold}/${n.threshold_type}/${join(",", n.contact_emails)}"
    ]) == toset(["80/Actual/ops@example.com", "100/Actual/ops@example.com"])
    error_message = "The budget must notify at 80 % and 100 % of the actual cost."
  }

  assert {
    condition     = azurerm_consumption_budget_subscription.monthly[0].subscription_id == "/subscriptions/00000000-0000-0000-0000-000000000000"
    error_message = "The budget must cover the current subscription."
  }
}

run "budget_default_start_date" {
  command = plan

  variables {
    budget_alert_email = "ops@example.com"
  }

  assert {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-01T00:00:00Z$", azurerm_consumption_budget_subscription.monthly[0].time_period[0].start_date))
    error_message = "Without budget_start_date the budget must start on the first day of the current month."
  }
}

run "rejects_empty_admin_cidrs" {
  command = plan

  variables {
    admin_cidrs = []
  }

  expect_failures = [var.admin_cidrs]
}

run "rejects_reserved_admin_username" {
  command = plan

  variables {
    admin_username = "admin"
  }

  expect_failures = [var.admin_username]
}

run "storage_account_defaults" {
  command = apply

  assert {
    condition = (
      azurerm_storage_account.this.name == "tetengoproddata" &&
      azurerm_storage_account.this.account_kind == "StorageV2" &&
      azurerm_storage_account.this.account_tier == "Standard" &&
      azurerm_storage_account.this.account_replication_type == "LRS" &&
      azurerm_storage_account.this.access_tier == "Hot" &&
      azurerm_storage_account.this.location == "chilecentral" &&
      azurerm_storage_account.this.resource_group_name == "te-tengo-prod-rg"
    )
    error_message = "The storage account must be a hot StorageV2 Standard_LRS named tetengoproddata in the environment's group and region."
  }

  assert {
    condition = (
      azurerm_storage_account.this.min_tls_version == "TLS1_2" &&
      azurerm_storage_account.this.https_traffic_only_enabled &&
      !azurerm_storage_account.this.allow_nested_items_to_be_public &&
      !azurerm_storage_account.this.shared_access_key_enabled &&
      azurerm_storage_account.this.default_to_oauth_authentication &&
      !azurerm_storage_account.this.local_user_enabled &&
      !azurerm_storage_account.this.sftp_enabled &&
      !azurerm_storage_account.this.cross_tenant_replication_enabled
    )
    error_message = "The storage account must be TLS 1.2+, HTTPS only, without public blobs, account keys, local users or SFTP."
  }

  # A deleted clip (consent revoked, retention) must really be deleted: no versions, no blob soft delete.
  assert {
    condition = (
      !azurerm_storage_account.this.blob_properties[0].versioning_enabled &&
      length(azurerm_storage_account.this.blob_properties[0].delete_retention_policy) == 0 &&
      azurerm_storage_account.this.blob_properties[0].container_delete_retention_policy[0].days == 7
    )
    error_message = "Blob versioning and blob soft delete must be off; only container soft delete (7 days) is on."
  }

  assert {
    condition     = length(azurerm_storage_account.this.blob_properties[0].cors_rule) == 0
    error_message = "Without storage_cors_allowed_origins there must be no CORS rule."
  }

  assert {
    condition = (
      toset([for c in azurerm_storage_container.this : c.name]) == toset(["clips", "movements", "backups"]) &&
      alltrue([for c in azurerm_storage_container.this : c.container_access_type == "private"])
    )
    error_message = "The account must hold exactly the private containers clips, movements and backups."
  }

  assert {
    condition = (
      length(azurerm_storage_management_policy.this.rule) == 1 &&
      azurerm_storage_management_policy.this.rule[0].name == "expire-old-dumps" &&
      azurerm_storage_management_policy.this.rule[0].filters[0].prefix_match == toset(["backups/"]) &&
      azurerm_storage_management_policy.this.rule[0].actions[0].base_blob[0].delete_after_days_since_modification_greater_than == 30
    )
    error_message = "By default only the dumps expire, after 30 days; clips are kept (clips_retention_days null)."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.app.identity[0].type == "SystemAssigned"
    error_message = "The VM must have a system-assigned managed identity."
  }

  assert {
    condition = (
      toset(keys(azurerm_role_assignment.vm_containers)) == toset(["clips", "movements", "backups"]) &&
      alltrue([for a in azurerm_role_assignment.vm_containers : a.role_definition_name == "Storage Blob Data Contributor" && a.principal_id == "11111111-1111-1111-1111-111111111111" && a.principal_type == "ServicePrincipal"]) &&
      azurerm_role_assignment.vm_containers["clips"].scope == azurerm_storage_container.this["clips"].id
    )
    error_message = "The VM identity must be Storage Blob Data Contributor on each container (container scope)."
  }

  assert {
    condition = (
      azurerm_role_assignment.vm_delegator.role_definition_name == "Storage Blob Delegator" &&
      azurerm_role_assignment.vm_delegator.scope == azurerm_storage_account.this.id &&
      azurerm_role_assignment.vm_delegator.principal_id == "11111111-1111-1111-1111-111111111111"
    )
    error_message = "The VM identity must be Storage Blob Delegator on the account (user delegation SAS)."
  }

  assert {
    condition = (
      length(azurerm_role_assignment.operator) == 1 &&
      azurerm_role_assignment.operator[0].principal_id == "44444444-4444-4444-4444-444444444444" &&
      azurerm_role_assignment.operator[0].role_definition_name == "Storage Blob Data Contributor" &&
      azurerm_role_assignment.operator[0].scope == azurerm_storage_account.this.id
    )
    error_message = "The operator (current client) must be Storage Blob Data Contributor on the account by default."
  }

  assert {
    condition = (
      output.storage_account_name == "tetengoproddata" &&
      output.storage_blob_endpoint == "https://tetengoproddata.blob.core.windows.net" &&
      output.clips_container_name == "clips" &&
      output.movements_container_name == "movements" &&
      output.backups_container_name == "backups" &&
      output.vm_principal_id == "11111111-1111-1111-1111-111111111111"
    )
    error_message = "The storage outputs are wrong (the endpoint has no trailing slash)."
  }
}

run "storage_cors_and_retention" {
  command = apply

  variables {
    storage_cors_allowed_origins  = ["https://app.tetengo.reqsai.tech", "https://te-tengo.pages.dev"]
    clips_retention_days          = 90
    backups_retention_days        = 14
    grant_operator_storage_access = false
    storage_account_suffix        = "st01"
  }

  assert {
    condition = (
      length(azurerm_storage_account.this.blob_properties[0].cors_rule) == 1 &&
      azurerm_storage_account.this.blob_properties[0].cors_rule[0].allowed_origins == tolist(["https://app.tetengo.reqsai.tech", "https://te-tengo.pages.dev"]) &&
      toset(azurerm_storage_account.this.blob_properties[0].cors_rule[0].allowed_methods) == toset(["GET", "HEAD", "PUT", "OPTIONS"]) &&
      contains(azurerm_storage_account.this.blob_properties[0].cors_rule[0].allowed_headers, "x-ms-blob-type") &&
      contains(azurerm_storage_account.this.blob_properties[0].cors_rule[0].allowed_headers, "content-type")
    )
    error_message = "The CORS rule must allow GET, HEAD, PUT and OPTIONS with content-type and x-ms-blob-type from the given origins."
  }

  assert {
    condition = (
      length(azurerm_storage_management_policy.this.rule) == 2 &&
      one([for r in azurerm_storage_management_policy.this.rule : r.actions[0].base_blob[0].delete_after_days_since_modification_greater_than if r.name == "clips-retention"]) == 90 &&
      one([for r in azurerm_storage_management_policy.this.rule : r.filters[0].prefix_match if r.name == "clips-retention"]) == toset(["clips/"]) &&
      one([for r in azurerm_storage_management_policy.this.rule : r.actions[0].base_blob[0].delete_after_days_since_modification_greater_than if r.name == "expire-old-dumps"]) == 14
    )
    error_message = "clips_retention_days must add a clips-retention rule and backups_retention_days must set the dumps' rule."
  }

  assert {
    condition     = length(azurerm_role_assignment.operator) == 0
    error_message = "grant_operator_storage_access = false must not create the operator's role assignment."
  }

  assert {
    condition     = azurerm_storage_account.this.name == "tetengoprodst01"
    error_message = "storage_account_suffix must end the account name."
  }
}

run "storage_account_name_too_long" {
  command = plan

  variables {
    environment            = "production-chile"
    storage_account_suffix = "abcdefghij"
  }

  expect_failures = [azurerm_storage_account.this]
}

run "rejects_an_invalid_storage_suffix" {
  command = plan

  variables {
    storage_account_suffix = "Data-1"
  }

  expect_failures = [var.storage_account_suffix]
}

run "rejects_a_cors_origin_with_a_path" {
  command = plan

  variables {
    storage_cors_allowed_origins = ["https://app.tetengo.reqsai.tech/"]
  }

  expect_failures = [var.storage_cors_allowed_origins]
}

run "webrtc_port_follows_the_variable" {
  command = apply

  variables {
    live_view_webrtc_port = 20000
  }

  assert {
    condition = toset([
      for rule in azurerm_network_security_group.app.security_rule : "${rule.protocol}/${rule.destination_port_range}"
      if startswith(rule.name, "allow-webrtc")
    ]) == toset(["Udp/20000", "Tcp/20000"]) && yamldecode(output.ansible_inventory).all.children.te_tengo.hosts["te-tengo-prod"].live_view_webrtc_port == 20000
    error_message = "The WebRTC rules and the inventory must follow live_view_webrtc_port."
  }
}

run "rejects_a_privileged_webrtc_port" {
  command = plan

  variables {
    live_view_webrtc_port = 443
  }

  expect_failures = [var.live_view_webrtc_port]
}
