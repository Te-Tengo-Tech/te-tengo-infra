# Public entry points of the host. There is no SSH rule: administration and Ansible go
# through SSM Session Manager, which only needs outbound HTTPS from the instance.
resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "Caddy (HTTP, HTTPS, HTTP/3) and MediaMTX RTSPS publish; no SSH"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name}-app"
  }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  # checkov:skip=CKV_AWS_260:Port 80 must be public for Let's Encrypt HTTP-01 challenges; Caddy only redirects it to HTTPS.
  security_group_id = aws_security_group.app.id
  description       = "HTTP for ACME challenges and the redirect to HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS: API, agent WebSocket and live view LL-HLS under /vivo"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "http3" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP/3 (QUIC)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "rtsps" {
  for_each = toset(var.live_view_publish_cidrs)

  security_group_id = aws_security_group.app.id
  description       = "RTSPS: household agents publish live view to MediaMTX"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = var.live_view_publish_port
  to_port           = var.live_view_publish_port
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  description       = "Image pulls, OS updates, SSM, S3, SES and Firebase Cloud Messaging"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
