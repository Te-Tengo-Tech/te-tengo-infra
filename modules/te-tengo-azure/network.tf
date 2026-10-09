# A dedicated, minimal virtual network: one subnet, no NAT gateway, no load balancer, no Bastion
# (PostgreSQL runs inside Docker Compose on the VM). The VM reaches the Internet through its own
# Standard public IP.

resource "azurerm_virtual_network" "this" {
  name                = "${local.name}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "app" {
  name                 = "${local.name}-app"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 0)]
}

locals {
  # Public entry points of the stack (compose/compose.yaml): Caddy on 80/TCP (ACME HTTP-01 and the
  # redirect), 443/TCP (API, WebSockets, LL-HLS under /vivo) and 443/UDP (HTTP/3), MediaMTX RTSPS;
  # SSH for the operator and Ansible. Everything else inbound hits the NSG's DenyAllInBound default.
  inbound_rules = {
    http = {
      priority = 100
      protocol = "Tcp"
      port     = "80"
      sources  = ["0.0.0.0/0"]
      purpose  = "Caddy: ACME HTTP-01 and the redirect to HTTPS"
    }
    https = {
      priority = 110
      protocol = "Tcp"
      port     = "443"
      sources  = ["0.0.0.0/0"]
      purpose  = "Caddy: API, WebSockets and LL-HLS"
    }
    http3 = {
      priority = 120
      protocol = "Udp"
      port     = "443"
      sources  = ["0.0.0.0/0"]
      purpose  = "Caddy: HTTP/3 (QUIC)"
    }
    rtsps = {
      priority = 130
      protocol = "Tcp"
      port     = tostring(var.live_view_publish_port)
      sources  = var.live_view_publish_cidrs
      purpose  = "MediaMTX RTSPS: household agents publish live view"
    }
    ssh = {
      priority = 140
      protocol = "Tcp"
      port     = "22"
      sources  = var.admin_cidrs
      purpose  = "SSH (keys only) for the operator and Ansible"
    }
  }
}

# Stateful rules: replies to allowed traffic are let back in automatically. Outbound keeps the NSG
# defaults (Internet allowed): image pulls, OS updates, Let's Encrypt, Cloudflare R2, the SMTP relay
# and Firebase Cloud Messaging.
resource "azurerm_network_security_group" "app" {
  # checkov:skip=CKV_AZURE_10:SSH is open to admin_cidrs, 0.0.0.0/0 by default on purpose (operator behind Cloudflare WARP, GitHub-hosted deploy runners); password authentication is disabled on the VM.
  name                = "${local.name}-app"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  dynamic "security_rule" {
    for_each = local.inbound_rules

    content {
      name                       = "allow-${security_rule.key}"
      description                = security_rule.value.purpose
      priority                   = security_rule.value.priority
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = security_rule.value.protocol
      source_port_range          = "*"
      destination_port_range     = security_rule.value.port
      source_address_prefixes    = security_rule.value.sources
      destination_address_prefix = "*"
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

# Standard SKU, static: the address survives stop/deallocate and only goes away with this resource.
# Billed per hour (docs/terraform.md, "Cost").
resource "azurerm_public_ip" "app" {
  name                = "${local.name}-ip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Standard"
  allocation_method   = "Static"
  ip_version          = "IPv4"
  tags                = local.tags
}

resource "azurerm_network_interface" "app" {
  # checkov:skip=CKV_AZURE_119:The VM needs a public IP: it serves the API, live view and RTSPS directly (no load balancer, to stay free).
  name                = "${local.name}-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.app.id
  }
}
