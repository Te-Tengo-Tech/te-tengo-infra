# Offline tests of the OCI module: the oracle/oci provider is mocked, so no tenancy, credentials or
# network are needed (`make tf-test`). They check the module's own logic: image and AD selection,
# security list rules, public IP modes, memory profile, the Always Free check and the inventory.

mock_provider "oci" {
  mock_data "oci_identity_availability_domains" {
    defaults = {
      availability_domains = [
        { id = "ad-1", name = "Xyz:SA-SANTIAGO-1-AD-1", compartment_id = "ocid1.tenancy.oc1..test" },
      ]
    }
  }

  mock_data "oci_core_images" {
    defaults = {
      images = [
        { id = "ocid1.image.oc1.sa-santiago-1.newest", display_name = "Canonical-Ubuntu-24.04-aarch64-2026.09.30-0" },
      ]
    }
  }

  mock_resource "oci_core_instance" {
    defaults = {
      public_ip = "192.0.2.10"
    }
  }

  mock_data "oci_core_vnic_attachments" {
    defaults = {
      vnic_attachments = [{ vnic_id = "ocid1.vnic.oc1..test" }]
    }
  }

  mock_data "oci_core_private_ips" {
    defaults = {
      private_ips = [{ id = "ocid1.privateip.oc1..test" }]
    }
  }

  mock_resource "oci_core_public_ip" {
    defaults = {
      ip_address = "192.0.2.20"
    }
  }
}

variables {
  region                  = "sa-santiago-1"
  tenancy_ocid            = "ocid1.tenancy.oc1..test"
  ssh_public_key          = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDKOTofJNaBqkM4ZkD/bzKoT9rZ5KyoClpW+tUX3hW/V test"
  admin_cidrs             = ["203.0.113.7/32"]
  app_hostname            = "api.tetengo.reqsai.tech"
  object_storage_endpoint = "https://0123456789abcdef.r2.cloudflarestorage.com"
  clips_bucket_name       = "te-tengo-clips"
  backups_bucket_name     = "te-tengo-backups"
}

run "always_free_defaults" {
  command = apply

  assert {
    condition     = oci_core_instance.app.shape == "VM.Standard.A1.Flex" && oci_core_instance.app.shape_config[0].ocpus == 1 && oci_core_instance.app.shape_config[0].memory_in_gbs == 6
    error_message = "The default host must be an A1.Flex with 1 OCPU and 6 GB (half of the Always Free allowance)."
  }

  assert {
    condition     = tonumber(oci_core_instance.app.source_details[0].boot_volume_size_in_gbs) == 50 && oci_core_instance.app.source_details[0].source_id == "ocid1.image.oc1.sa-santiago-1.newest"
    error_message = "The boot volume must be 50 GB from the newest Ubuntu image."
  }

  assert {
    condition     = oci_core_instance.app.availability_domain == "Xyz:SA-SANTIAGO-1-AD-1"
    error_message = "The first availability domain must be used by default."
  }

  assert {
    condition     = oci_core_instance.app.create_vnic_details[0].assign_public_ip == "true" && length(oci_core_public_ip.reserved) == 0
    error_message = "ephemeral mode assigns the public IP with the VNIC and reserves none."
  }

  assert {
    condition     = oci_core_instance.app.instance_options[0].are_legacy_imds_endpoints_disabled
    error_message = "Legacy IMDS endpoints must be disabled."
  }

  assert {
    condition     = output.public_ip == "192.0.2.10" && output.app_url == "https://api.tetengo.reqsai.tech"
    error_message = "Public IP and URL come from the ephemeral IP and app_hostname."
  }

  assert {
    condition     = output.dns_record == "api.tetengo.reqsai.tech. 300 IN A 192.0.2.10"
    error_message = "The DNS record to create by hand is wrong."
  }

  assert {
    condition     = output.memory_profile == "large" && output.instance_architecture == "arm64"
    error_message = "6 GB on A1 must give the 'large' profile on arm64."
  }

  # SSH only from admin_cidrs; 80, 443 (TCP and UDP) and 8322 from anywhere.
  assert {
    condition = toset([
      for rule in oci_core_security_list.app.ingress_security_rules : rule.source
      if rule.protocol == "6" && one(rule.tcp_options[*].min) == 22
    ]) == toset(["203.0.113.7/32"])
    error_message = "SSH must be open only to admin_cidrs."
  }

  assert {
    condition = toset([
      for rule in oci_core_security_list.app.ingress_security_rules : "${rule.protocol}/${coalesce(one(rule.tcp_options[*].min), one(rule.udp_options[*].min), 0)}"
      if rule.source == "0.0.0.0/0" && rule.protocol != "1"
    ]) == toset(["6/80", "6/443", "17/443", "6/8322"])
    error_message = "Only 80/TCP, 443/TCP, 443/UDP and 8322/TCP may be open to the Internet."
  }

  assert {
    condition     = length(oci_core_default_security_list.this.ingress_security_rules) == 0 && length(oci_core_default_security_list.this.egress_security_rules) == 0
    error_message = "The default security list must be emptied."
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
      cloud_provider               = "oci"
      cloud_region                 = "sa-santiago-1"
      memory_profile               = "large"
      instance_architecture        = "arm64"
      object_storage_endpoint      = "https://0123456789abcdef.r2.cloudflarestorage.com"
      object_storage_region        = "auto"
      object_storage_path_style    = true
      object_storage_auth          = "static"
      clips_s3_bucket              = "te-tengo-clips"
      backup_s3_bucket             = "te-tengo-backups"
      ses_sender                   = ""
      push_provider                = "fcm"
      sns_platform_application_arn = ""
      live_view_publish_port       = 8322
    }
    error_message = "The rendered inventory does not match docs/interface-terraform-ansible.md."
  }
}

run "reserved_public_ip_and_sslip" {
  command = apply

  variables {
    public_ip_mode = "reserved"
    app_hostname   = ""
    memory_in_gbs  = 4
  }

  assert {
    condition     = oci_core_instance.app.create_vnic_details[0].assign_public_ip == "false" && oci_core_public_ip.reserved[0].lifetime == "RESERVED"
    error_message = "reserved mode must start the VNIC without a public IP and reserve one."
  }

  assert {
    condition     = output.public_ip == "192.0.2.20" && output.app_hostname == "192-0-2-20.sslip.io" && output.dns_record == ""
    error_message = "Without app_hostname the reserved IP must give an sslip.io name."
  }

  assert {
    condition     = output.memory_profile == "medium"
    error_message = "4 GB must give the 'medium' profile."
  }
}

run "beyond_always_free_warns" {
  command = plan

  variables {
    ocpus         = 2
    memory_in_gbs = 16
  }

  expect_failures = [check.always_free_allowance]
}

run "rejects_empty_admin_cidrs" {
  command = plan

  variables {
    admin_cidrs = []
  }

  expect_failures = [var.admin_cidrs]
}

run "rejects_plain_http_endpoint" {
  command = plan

  variables {
    object_storage_endpoint = "http://example.com"
  }

  expect_failures = [var.object_storage_endpoint]
}
