# Optional (enable_ses, off by default: the API sends through an SMTP relay configured in Ansible).
# Sender identities for the API's 'ses' e-mail provider (TT_SES_REMITENTE).
# - The e-mail identity is verified by clicking the link SES sends to that address.
# - The optional domain identity uses Easy DKIM; its three CNAMEs go to Route53 when the domain
#   is inside dns_zone_name, otherwise to the DNS provider by hand (output ses_dkim_records).
# A new account is in the SES sandbox (it only sends to verified addresses) until production
# access is requested; see docs/terraform.md.
locals {
  ses_email_identity  = var.enable_ses && var.ses_sender_email != ""
  ses_domain_identity = var.enable_ses && var.ses_domain != ""
  ses_dkim_in_route53 = local.ses_domain_identity && local.use_route53 && (var.ses_domain == var.dns_zone_name || endswith(var.ses_domain, ".${var.dns_zone_name}"))
}

resource "aws_sesv2_email_identity" "sender" {
  count = local.ses_email_identity ? 1 : 0

  email_identity = var.ses_sender_email
}

resource "aws_sesv2_email_identity" "domain" {
  count = local.ses_domain_identity ? 1 : 0

  email_identity = var.ses_domain
}

resource "aws_route53_record" "ses_dkim" {
  count = local.ses_dkim_in_route53 ? 3 : 0

  zone_id = data.aws_route53_zone.selected[0].zone_id
  name    = "${aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.ses_domain}"
  type    = "CNAME"
  ttl     = 1800
  records = ["${aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}
