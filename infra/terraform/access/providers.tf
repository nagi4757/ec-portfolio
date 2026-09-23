# No default_tags: this root adopts existing Identity Center objects and owns
# nothing that carries tags.
provider "aws" {
  region = local.aws_region
}
