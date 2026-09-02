locals {
  aws_region  = "ap-northeast-1"
  name_prefix = "ec-portfolio-demo"
  vpc_cidr    = "10.20.0.0/16"

  subnet_cidrs = {
    public_app   = "10.20.0.0/24"
    private_db_a = "10.20.10.0/24"
    private_db_b = "10.20.11.0/24"
  }

  base_domain                  = "yoonec.dev"
  origin_hostname              = "origin-demo.${local.base_domain}"
  origin_acme_challenge_record = "_acme-challenge.${local.origin_hostname}"

  common_tags = {
    Project     = "ec-portfolio"
    Environment = "demo"
    Owner       = var.owner
  }
}
