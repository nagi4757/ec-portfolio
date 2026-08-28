provider "aws" {
  region = local.aws_region

  default_tags {
    tags = local.common_tags
  }
}
