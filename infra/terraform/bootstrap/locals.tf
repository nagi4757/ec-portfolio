data "aws_caller_identity" "current" {}

locals {
  aws_region  = "ap-northeast-1"
  name_prefix = "ec-portfolio-terraform-state"
  bucket_name = "${local.name_prefix}-${data.aws_caller_identity.current.account_id}-${local.aws_region}"

  common_tags = {
    Project     = "ec-portfolio"
    Environment = "demo"
    Owner       = var.owner
    AutoStop    = "false"
    ManagedBy   = "terraform-bootstrap"
  }
}
