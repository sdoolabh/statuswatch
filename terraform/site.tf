# Phase 3: the public face. CloudFront in front of the SAME data bucket the
# normalizer writes status.json into — the page and its data share one
# origin, one cert, one domain. Drop this file into terraform/ and add the
# `domain` variable value if you override the default.

variable "domain" {
  description = "Root domain with an existing Route53 hosted zone"
  type        = string
  default     = "shanedoolabh.com"
}

variable "subdomain" {
  type    = string
  default = "status"
}

locals {
  site_fqdn = "${var.subdomain}.${var.domain}"
}

data "aws_route53_zone" "root" {
  name         = var.domain
  private_zone = false
}

# CloudFront requires its cert in us-east-1 — which is already our region,
# so no provider alias gymnastics needed.
resource "aws_acm_certificate" "site" {
  domain_name       = local.site_fqdn
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "site_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.site.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }
  zone_id         = data.aws_route53_zone.root.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "site" {
  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for r in aws_route53_record.site_cert_validation : r.fqdn]
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "statuswatch-site"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [local.site_fqdn]
  price_class         = "PriceClass_100"
  comment             = "statuswatch public site + status.json"

  origin {
    domain_name              = aws_s3_bucket.data.bucket_regional_domain_name
    origin_id                = "s3-data"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-data"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    # Managed CachingOptimized: honors origin Cache-Control headers, which is
    # the whole freshness mechanism — the normalizer writes status.json with
    # max-age=60, so edges re-fetch it about once a minute. The page itself
    # is uploaded with a longer max-age.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }
}

# Allow ONLY this distribution to read the data bucket. The bucket stays
# fully private otherwise — public access blocks remain on.
resource "aws_s3_bucket_policy" "data_cloudfront" {
  bucket = aws_s3_bucket.data.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.data.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.site.arn }
      }
    }]
  })
}

resource "aws_route53_record" "site" {
  for_each = toset(["A", "AAAA"])
  zone_id  = data.aws_route53_zone.root.zone_id
  name     = local.site_fqdn
  type     = each.value
  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

output "site_url" {
  value = "https://${local.site_fqdn}"
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.site.id
}
