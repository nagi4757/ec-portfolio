data "aws_route53_zone" "demo_public" {
  name         = "${local.base_domain}."
  private_zone = false

  lifecycle {
    postcondition {
      condition     = self.zone_id == var.route53_public_hosted_zone_id
      error_message = "The discovered public yoonec.dev hosted zone must exactly match route53_public_hosted_zone_id."
    }
  }
}

resource "aws_route53_record" "origin_demo" {
  zone_id = data.aws_route53_zone.demo_public.zone_id
  name    = local.origin_hostname
  type    = "A"
  ttl     = 60
  records = [aws_eip.ec2_origin.public_ip]
}
