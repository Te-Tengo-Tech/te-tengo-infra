# A dedicated, minimal VPC: one public subnet and an internet gateway, no NAT gateway
# (the most expensive piece of a "classic" VPC) and no private subnets, since PostgreSQL
# runs inside Docker Compose on the instance.

resource "aws_vpc" "this" {
  # checkov:skip=CKV2_AWS_11:VPC flow logs cost CloudWatch ingestion; not justified for the MVP.
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = local.name
  }
}

# Strip every rule from the default security group so nothing can use it by accident.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name}-default-unused"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = local.name
  }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone = local.availability_zone

  # The instance gets its public address from the Elastic IP, not from the subnet.
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name}-public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${local.name}-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
