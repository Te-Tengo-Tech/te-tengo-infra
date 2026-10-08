# Instance role: always SSM (Session Manager). With enable_s3_buckets / enable_ses / enable_sns the
# API and the backup timer also use it through the AWS SDK default credential chain (IMDSv2), so no
# static AWS key is written to the host; with the defaults (R2, SMTP) they use keys from the vault.

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${local.name}-ec2"
  description        = "Te Tengo ${var.environment} host: SSM, plus S3, SES and SNS when enabled."
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

locals {
  ses_identity_arns = concat(
    [for identity in aws_sesv2_email_identity.sender : identity.arn],
    [for identity in aws_sesv2_email_identity.domain : identity.arn],
  )
  # Without S3, SES or SNS the role only carries the SSM managed policy (an empty inline policy is invalid).
  app_policy_needed = var.enable_s3_buckets || local.ses_email_identity || local.ses_domain_identity || var.enable_sns
  sns_endpoints_arn = var.enable_sns ? "arn:${local.partition}:sns:${var.aws_region}:${local.account_id}:endpoint/GCM/${aws_sns_platform_application.fcm[0].name}/*" : ""
}

data "aws_iam_policy_document" "app" {
  count = local.app_policy_needed ? 1 : 0

  # Pre-signed PUT (agent upload) and GET (app playback) URLs carry the signer's permissions;
  # HeadObject checks the upload and DeleteObject applies consent revocation and retention.
  dynamic "statement" {
    for_each = var.enable_s3_buckets ? [1] : []

    content {
      sid       = "ListClips"
      actions   = ["s3:ListBucket"]
      resources = [aws_s3_bucket.this["clips"].arn]
    }
  }

  dynamic "statement" {
    for_each = var.enable_s3_buckets ? [1] : []

    content {
      sid       = "ReadWriteDeleteClips"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["${aws_s3_bucket.this["clips"].arn}/*"]
    }
  }

  # Write-only: the host uploads dumps; restores use the operator's own credentials.
  dynamic "statement" {
    for_each = var.enable_s3_buckets ? [1] : []

    content {
      sid       = "WriteBackups"
      actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
      resources = ["${aws_s3_bucket.this["backups"].arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = length(local.ses_identity_arns) > 0 ? [1] : []

    content {
      sid       = "SendEmail"
      actions   = ["ses:SendEmail", "ses:SendRawEmail"]
      resources = local.ses_identity_arns

      dynamic "condition" {
        for_each = var.ses_sender_email != "" ? [var.ses_sender_email] : []

        content {
          test     = "StringEquals"
          variable = "ses:FromAddress"
          values   = [condition.value]
        }
      }
    }
  }

  dynamic "statement" {
    for_each = var.enable_sns ? [1] : []

    content {
      sid       = "CreatePushEndpoints"
      actions   = ["sns:CreatePlatformEndpoint"]
      resources = [aws_sns_platform_application.fcm[0].arn]
    }
  }

  dynamic "statement" {
    for_each = var.enable_sns ? [1] : []

    content {
      sid       = "UsePushEndpoints"
      actions   = ["sns:Publish", "sns:GetEndpointAttributes", "sns:SetEndpointAttributes"]
      resources = [local.sns_endpoints_arn]
    }
  }
}

resource "aws_iam_role_policy" "app" {
  count = local.app_policy_needed ? 1 : 0

  name   = "${local.name}-app"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app[0].json
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name}-ec2"
  role = aws_iam_role.app.name
}
