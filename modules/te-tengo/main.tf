data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_ec2_instance_type" "selected" {
  count = var.instance_type_facts == null ? 1 : 0

  instance_type = var.instance_type
}

data "aws_ec2_instance_type_offerings" "selected" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

data "aws_ami" "ubuntu" {
  count = var.ami_id == null ? 1 : 0

  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${local.ami_architecture}-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  instance_type_facts = var.instance_type_facts != null ? var.instance_type_facts : {
    architectures = data.aws_ec2_instance_type.selected[0].supported_architectures
    memory_mib    = data.aws_ec2_instance_type.selected[0].memory_size
    burstable     = data.aws_ec2_instance_type.selected[0].burstable_performance_supported
  }

  name       = "${var.project}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  ami_architecture  = contains(local.instance_type_facts.architectures, "arm64") ? "arm64" : "amd64"
  ami_id            = var.ami_id != null ? var.ami_id : data.aws_ami.ubuntu[0].id
  availability_zone = coalesce(var.availability_zone, sort(data.aws_ec2_instance_type_offerings.selected.locations)[0])
  memory_profile    = coalesce(var.memory_profile, local.instance_type_facts.memory_mib >= 2048 ? "small" : "micro")

  use_route53    = var.dns_zone_name != ""
  sslip_hostname = "${replace(aws_eip.app.public_ip, ".", "-")}.sslip.io"
  app_hostname   = local.use_route53 ? "${var.dns_record_name}.${var.dns_zone_name}" : local.sslip_hostname

  ses_sender = var.enable_ses && var.ses_sender_email != "" ? "${var.ses_sender_name} <${var.ses_sender_email}>" : ""
}
