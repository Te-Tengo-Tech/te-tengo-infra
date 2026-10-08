# Instance role: the API and the backup timer use it through the AWS SDK default credential
# chain (IMDSv2), so no static AWS key is ever written to the host.

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
  description        = "Te Tengo ${var.environment} host: clips presigning, SES, backups and SSM."
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
  sns_endpoints_arn = var.enable_sns ? "arn:${local.partition}:sns:${var.aws_region}:${local.account_id}:endpoint/GCM/${aws_sns_platform_application.fcm[0].name}/*" : ""
}

data "aws_iam_policy_document" "app" {
  # Pre-signed PUT (agent upload) and GET (app playback) URLs carry the signer's permissions;
  # HeadObject checks the upload and DeleteObject applies consent revocation and retention.
  statement {
    sid       = "ListClips"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this["clips"].arn]
  }

  statement {
    sid       = "ReadWriteDeleteClips"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.this["clips"].arn}/*"]
  }

  # Write-only: the host uploads dumps; restores use the operator's own credentials.
  statement {
    sid       = "WriteBackups"
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${aws_s3_bucket.this["backups"].arn}/*"]
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
  name   = "${local.name}-app"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name}-ec2"
  role = aws_iam_role.app.name
}
