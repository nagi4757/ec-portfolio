data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "ec2_origin" {
  name        = "${local.name_prefix}-ec2-origin"
  description = "Demo EC2 origin: CloudFront HTTPS ingress and explicit runtime egress"
  vpc_id      = aws_vpc.demo.id

  tags = {
    Name = "${local.name_prefix}-ec2-origin"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ec2_origin_https_from_cloudfront" {
  security_group_id = aws_security_group.ec2_origin.id
  description       = "HTTPS from the CloudFront origin-facing managed prefix list only"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "ec2_origin_https" {
  security_group_id = aws_security_group.ec2_origin.id
  description       = "HTTPS for ECR, SSM, CloudWatch, AWS APIs, and approved package repositories"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds"
  description = "Private Demo RDS access from the EC2 origin security group only"
  vpc_id      = aws_vpc.demo.id

  tags = {
    Name = "${local.name_prefix}-rds"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_mysql_from_ec2_origin" {
  security_group_id            = aws_security_group.rds.id
  description                  = "MariaDB from the Demo EC2 origin security group only"
  referenced_security_group_id = aws_security_group.ec2_origin.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "ec2_origin_mysql_to_rds" {
  security_group_id            = aws_security_group.ec2_origin.id
  description                  = "MariaDB connections to the private RDS security group"
  referenced_security_group_id = aws_security_group.rds.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
}
