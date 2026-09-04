locals {
  frontends = toset(["store", "admin"])
}

resource "aws_s3_bucket" "frontend" {
  for_each = local.frontends

  bucket_prefix = "${local.name_prefix}-${each.key}-"
  force_destroy = false

  tags = {
    Name = "${local.name_prefix}-${each.key}"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  for_each = local.frontends

  bucket                  = aws_s3_bucket.frontend[each.key].id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "frontend" {
  for_each = local.frontends

  bucket = aws_s3_bucket.frontend[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  for_each = local.frontends

  bucket = aws_s3_bucket.frontend[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  for_each = local.frontends

  name                              = "${local.name_prefix}-${each.key}"
  description                       = "Read the private ${each.key} static origin with signed HTTPS requests"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket_policy" "frontend" {
  for_each = local.frontends

  bucket = aws_s3_bucket.frontend[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowOwnCloudFrontDistributionRead"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend[each.key].arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.frontend[each.key].arn
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.frontend[each.key].arn,
          "${aws_s3_bucket.frontend[each.key].arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })

  depends_on = [
    aws_s3_bucket_public_access_block.frontend,
    aws_s3_bucket_ownership_controls.frontend,
  ]
}

resource "aws_cloudfront_cache_policy" "frontend_shell" {
  name        = "${local.name_prefix}-frontend-shell"
  comment     = "Revalidate HTML by default and cap origin-provided caching at 60 seconds"
  min_ttl     = 0
  default_ttl = 0
  max_ttl     = 60

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true

    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

resource "aws_cloudfront_cache_policy" "frontend_assets" {
  name        = "${local.name_prefix}-frontend-assets"
  comment     = "Cache content-hashed assets; the deployment sets immutable object metadata"
  min_ttl     = 0
  default_ttl = 86400
  max_ttl     = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true

    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

resource "aws_cloudfront_function" "frontend_spa_rewrite" {
  name    = "${local.name_prefix}-frontend-spa-rewrite"
  runtime = "cloudfront-js-2.0"
  comment = "Rewrite extensionless frontend navigation without masking API or asset failures"
  publish = true
  code    = file("${path.module}/functions/frontend-spa-rewrite.js")
}

resource "aws_cloudfront_distribution" "frontend" {
  for_each = local.frontends

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Demo ${each.key} static frontend"
  price_class         = "PriceClass_200"
  default_root_object = "index.html"
  aliases             = []

  origin {
    domain_name              = aws_s3_bucket.frontend[each.key].bucket_regional_domain_name
    origin_id                = "${local.name_prefix}-${each.key}"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend[each.key].id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "${local.name_prefix}-${each.key}"
    cache_policy_id        = aws_cloudfront_cache_policy.frontend_shell.id
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.frontend_spa_rewrite.arn
    }
  }

  ordered_cache_behavior {
    path_pattern           = "/assets/*"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "${local.name_prefix}-${each.key}"
    cache_policy_id        = aws_cloudfront_cache_policy.frontend_assets.id
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
  }

  # Keep real asset/origin failures as failures, not HTML 200 responses.
  dynamic "custom_error_response" {
    for_each = [403, 404]

    content {
      error_code            = custom_error_response.value
      error_caching_min_ttl = 0
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["JP", "KR"]
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "${local.name_prefix}-${each.key}"
  }
}
