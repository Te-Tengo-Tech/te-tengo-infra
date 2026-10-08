resource "aws_key_pair" "admin" {
  count = var.ssh_public_key != null ? 1 : 0

  key_name   = "${local.name}-admin"
  public_key = var.ssh_public_key
}

resource "aws_instance" "app" {
  # checkov:skip=CKV_AWS_126:Detailed monitoring is billed per metric; basic 5-minute metrics are enough for the MVP.
  ami                                  = local.ami_id
  instance_type                        = var.instance_type
  subnet_id                            = aws_subnet.public.id
  vpc_security_group_ids               = [aws_security_group.app.id]
  key_name                             = one(aws_key_pair.admin[*].key_name)
  iam_instance_profile                 = aws_iam_instance_profile.app.name
  disable_api_termination              = var.termination_protection
  instance_initiated_shutdown_behavior = "stop"
  ebs_optimized                        = true
  monitoring                           = false

  dynamic "credit_specification" {
    for_each = local.instance_type_facts.burstable ? [var.cpu_credits] : []

    content {
      cpu_credits = credit_specification.value
    }
  }

  # IMDSv2 only. Two hops, because the API runs in a container on a Docker bridge network and
  # signs S3 URLs and SES calls with the instance role (AWS SDK default chain); with one hop the
  # IMDSv2 token response would be dropped before reaching the container.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = var.imds_hop_limit
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name = "${local.name}-root"
    }
  }

  tags = {
    Name = local.name
  }

  lifecycle {
    # A newer Ubuntu AMI must not replace the host (and its database).
    ignore_changes = [ami]
  }
}

resource "aws_eip" "app" {
  domain = "vpc"

  tags = {
    Name = local.name
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_eip_association" "app" {
  instance_id   = aws_instance.app.id
  allocation_id = aws_eip.app.id
}
