locals {
  aws_region  = "ap-northeast-1"
  name_prefix = "ec-portfolio-demo"
  vpc_cidr    = "10.20.0.0/16"

  # al2023-ami-2023.12.20260831.0-kernel-6.18-x86_64
  #
  # Pinned to an exact image rather than resolved from the AWS-managed
  # /aws/service/ami-amazon-linux-latest/... parameter. That parameter is a
  # mutable pointer, and because ami forces replacement on aws_instance, every
  # AWS release of a new AL2023 image turned into a plan that destroys the Demo
  # host. Upgrades happen through an explicit PR that changes this value, not as
  # a side effect of someone running plan on a day AWS published an image.
  #
  # See the AMI lifecycle section of README.md before changing this.
  demo_ami_id = "ami-0794a632d5c1058bf"

  # al2023-ami-ecs-hvm-2023.0.20260914-kernel-6.1-x86_64
  #
  # Pinned for the Phase 6C ECS EC2 Spot hosts, which are planned and not yet
  # built. The AWS-managed /aws/service/ecs/optimized-ami/... parameter is used
  # to discover a candidate image, never referenced from Terraform: it is a
  # mutable pointer, and an ami change forces a new launch template version and
  # an instance refresh. Upgrades happen through an explicit PR that changes
  # this value, for the same reason demo_ami_id is pinned above.
  #
  # Held separately from demo_ami_id on purpose. The two hosts run different
  # images for different lifecycles -- the On-Demand origin host keeps serving
  # until the Phase 6C cutover completes -- so one constant must not drag the
  # other along.
  #
  # The image ships a 30 GiB gp3 root snapshot. A launch template must not
  # request a smaller root volume than the snapshot it restores.
  ecs_ami_id = "ami-09fabc8f577a34419"

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
