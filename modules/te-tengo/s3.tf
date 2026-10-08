# Two private buckets with the same hardening:
# - clips:   fall clips. The household agent uploads with a pre-signed PUT and the app plays them
#            with a pre-signed GET (both signed by the API with the instance role), so the
#            bucket is never public and the backend never relays video bytes.
# - backups: off-host copies of the daily pg_dump; expire after backups_retention_days.
#
# Neither bucket is versioned: deleting a clip (consent revoked, retention) must really delete
# it, and dumps already have their own retention. SSE-S3 (AES256) avoids KMS request charges.
locals {
  buckets = {
    clips   = "${local.name}-clips-${local.account_id}"
    backups = "${local.name}-backups-${local.account_id}"
  }
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  # checkov:skip=CKV_AWS_18:Server access logs need a third bucket and add cost; CloudTrail management events are enough for the MVP.
  # checkov:skip=CKV_AWS_144:Cross-region replication doubles storage cost; out of scope for the MVP.
  # checkov:skip=CKV_AWS_145:SSE-S3 (AES256) is used on purpose; SSE-KMS bills every request.
  # checkov:skip=CKV_AWS_21:Not versioned on purpose: deleted clips must not survive as old versions (consent revocation), and dumps expire.
  # checkov:skip=CKV2_AWS_62:No consumer for S3 event notifications.
  bucket        = each.value
  force_destroy = var.force_destroy_buckets

  tags = {
    Name    = each.value
    Purpose = each.key
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = local.buckets

  bucket                  = aws_s3_bucket.this[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

data "aws_iam_policy_document" "bucket_tls_only" {
  for_each = local.buckets

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.this[each.key].arn,
      "${aws_s3_bucket.this[each.key].arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id
  policy = data.aws_iam_policy_document.bucket_tls_only[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "aws_s3_bucket_lifecycle_configuration" "clips" {
  bucket = aws_s3_bucket.this["clips"].id

  rule {
    id     = "clips-retention"
    status = "Enabled"

    filter {}

    # Only when the team sets a retention; null keeps the clips.
    dynamic "expiration" {
      for_each = var.clips_retention_days == null ? [] : [var.clips_retention_days]

      content {
        days = expiration.value
      }
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.this["backups"].id

  rule {
    id     = "expire-old-dumps"
    status = "Enabled"

    filter {}

    expiration {
      days = var.backups_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "clips" {
  count = length(var.clips_cors_allowed_origins) > 0 ? 1 : 0

  bucket = aws_s3_bucket.this["clips"].id

  cors_rule {
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = var.clips_cors_allowed_origins
    allowed_headers = ["*"]
    expose_headers  = ["Content-Length", "Content-Type", "Content-Range", "ETag"]
    max_age_seconds = 3000
  }
}
