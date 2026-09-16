# Phase 6B: durable storage for the origin TLS state.
#
# A replacement host must be able to serve without asking Let's Encrypt for a
# new certificate. Issuing on every boot would hit the five duplicate
# certificates per week limit within days, so the certbot state is archived here
# and restored instead.
#
# The object holds the whole /etc/letsencrypt tree as a tar archive, not the
# PEMs alone: live/ is a directory of symlinks into archive/, and accounts/
# holds the ACME account key. A host restored without them can serve today and
# cannot renew.

resource "aws_s3_bucket" "origin_tls" {
  bucket_prefix = "${local.name_prefix}-origin-tls-"
  force_destroy = false

  tags = {
    Name = "${local.name_prefix}-origin-tls"
  }
}

resource "aws_s3_bucket_public_access_block" "origin_tls" {
  bucket                  = aws_s3_bucket.origin_tls.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "origin_tls" {
  bucket = aws_s3_bucket.origin_tls.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "origin_tls" {
  bucket = aws_s3_bucket.origin_tls.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Versioning is the recovery path for a bad backup: the instance role may
# overwrite the object but cannot delete it, so an earlier known good archive
# always remains reachable by an operator.
resource "aws_s3_bucket_versioning" "origin_tls" {
  bucket = aws_s3_bucket.origin_tls.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "origin_tls" {
  bucket     = aws_s3_bucket.origin_tls.id
  depends_on = [aws_s3_bucket_versioning.origin_tls]

  rule {
    id     = "expire-noncurrent-archives"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Only the transport rule is expressed here. A blanket "deny every principal
# except the instance role" would also lock out Terraform and operators holding
# legitimate administrative access, and recovering from that requires the root
# account. Access is instead narrowed on the identity side, where the instance
# role is granted exactly two actions on exactly one object.
data "aws_iam_policy_document" "origin_tls_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.origin_tls.arn,
      "${aws_s3_bucket.origin_tls.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "origin_tls" {
  bucket = aws_s3_bucket.origin_tls.id
  policy = data.aws_iam_policy_document.origin_tls_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.origin_tls]
}
