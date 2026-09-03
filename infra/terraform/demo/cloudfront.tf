data "aws_cloudfront_cache_policy" "caching_disabled" {
  # AWS-managed CachingDisabled policy; this is not an account-specific ID.
  id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
}

resource "aws_cloudfront_origin_request_policy" "api" {
  name    = "${local.name_prefix}-api-origin"
  comment = "Forward only approved API viewer headers, plus all cookies and query strings"

  cookies_config {
    cookie_behavior = "all"
  }

  headers_config {
    header_behavior = "whitelist"

    headers {
      items = [
        "Accept",
        "Access-Control-Request-Headers",
        "Access-Control-Request-Method",
        "Authorization",
        "Content-Type",
        "Origin",
        "X-Correlation-ID",
      ]
    }
  }

  query_strings_config {
    query_string_behavior = "all"
  }
}

resource "aws_cloudfront_distribution" "api" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "Demo API HTTPS distribution"
  price_class     = "PriceClass_200"
  aliases         = []

  origin {
    domain_name = local.origin_hostname
    origin_id   = "${local.name_prefix}-api"

    custom_header {
      name  = "X-Origin-Verify"
      value = var.cloudfront_origin_verify_token
    }

    custom_origin_config {
      # Required by the provider; https-only never uses the HTTP port.
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "${local.name_prefix}-api"
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.api.id
    viewer_protocol_policy   = "redirect-to-https"
  }

  # Error caching has a separate TTL. Preserve API status codes without caching errors.
  # CloudFront never caches 416 responses, so that status needs no override.
  dynamic "custom_error_response" {
    for_each = [400, 403, 404, 405, 414, 500, 501, 502, 503, 504]

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
    Name = "${local.name_prefix}-api"
  }
}
