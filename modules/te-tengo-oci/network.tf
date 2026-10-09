# A dedicated, minimal VCN: one public subnet and an internet gateway, no NAT gateway and no
# private subnet, since PostgreSQL runs inside Docker Compose on the instance.

resource "oci_core_vcn" "this" {
  compartment_id = local.compartment_id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = local.name
  dns_label      = "tetengo"
  freeform_tags  = local.freeform_tags
}

# The default security list of a new VCN opens SSH to 0.0.0.0/0. Strip every rule so nothing can use
# it by accident; the subnet uses the security list below.
resource "oci_core_default_security_list" "this" {
  manage_default_resource_id = oci_core_vcn.this.default_security_list_id
  compartment_id             = local.compartment_id
  display_name               = "${local.name}-default-unused"
  freeform_tags              = local.freeform_tags
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = local.name
  enabled        = true
  freeform_tags  = local.freeform_tags
}

resource "oci_core_route_table" "public" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.name}-public"
  freeform_tags  = local.freeform_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

locals {
  # Public entry points of the stack (compose/compose.yaml): Caddy on 80/TCP (ACME HTTP-01 and the
  # redirect), 443/TCP (API, WebSockets, LL-HLS under /vivo, WHEP under /vivo-webrtc) and 443/UDP
  # (HTTP/3), MediaMTX RTSPS and MediaMTX WebRTC media (live_view_webrtc_port, UDP and TCP).
  public_tcp_ports = {
    http  = 80
    https = 443
  }
}

# Stateful rules: replies to allowed traffic are let back in automatically.
resource "oci_core_security_list" "app" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.name}-app"
  freeform_tags  = local.freeform_tags

  egress_security_rules {
    description = "Image pulls, OS updates, Let's Encrypt, Cloudflare R2, SMTP relay and Firebase Cloud Messaging"
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  dynamic "ingress_security_rules" {
    for_each = local.public_tcp_ports

    content {
      description = "Caddy ${ingress_security_rules.key}"
      source      = "0.0.0.0/0"
      protocol    = "6"

      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }

  ingress_security_rules {
    description = "HTTP/3 (QUIC)"
    source      = "0.0.0.0/0"
    protocol    = "17"

    udp_options {
      min = 443
      max = 443
    }
  }

  ingress_security_rules {
    description = "WebRTC: live view media from MediaMTX to the app (ICE over UDP)"
    source      = "0.0.0.0/0"
    protocol    = "17"

    udp_options {
      min = var.live_view_webrtc_port
      max = var.live_view_webrtc_port
    }
  }

  ingress_security_rules {
    description = "WebRTC: live view media where UDP is blocked (ICE over TCP)"
    source      = "0.0.0.0/0"
    protocol    = "6"

    tcp_options {
      min = var.live_view_webrtc_port
      max = var.live_view_webrtc_port
    }
  }

  dynamic "ingress_security_rules" {
    for_each = toset(var.live_view_publish_cidrs)

    content {
      description = "RTSPS: household agents publish live view to MediaMTX"
      source      = ingress_security_rules.value
      protocol    = "6"

      tcp_options {
        min = var.live_view_publish_port
        max = var.live_view_publish_port
      }
    }
  }

  dynamic "ingress_security_rules" {
    for_each = toset(var.admin_cidrs)

    content {
      description = "SSH for the operator and Ansible"
      source      = ingress_security_rules.value
      protocol    = "6"

      tcp_options {
        min = 22
        max = 22
      }
    }
  }

  # Path MTU discovery ("fragmentation needed"), as in OCI's default security list.
  ingress_security_rules {
    description = "ICMP fragmentation needed (path MTU discovery)"
    source      = "0.0.0.0/0"
    protocol    = "1"

    icmp_options {
      type = 3
      code = 4
    }
  }

  ingress_security_rules {
    description = "ICMP destination unreachable inside the VCN"
    source      = var.vcn_cidr
    protocol    = "1"

    icmp_options {
      type = 3
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = local.compartment_id
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = cidrsubnet(var.vcn_cidr, 8, 0)
  display_name               = "${local.name}-public"
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.app.id]
  prohibit_public_ip_on_vnic = false
  freeform_tags              = local.freeform_tags
}
