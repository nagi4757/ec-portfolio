resource "aws_iam_role" "ec2" {
  name        = "${local.name_prefix}-ec2"
  description = "Demo EC2 role for Systems Manager managed-instance access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-ec2"
  }
}

resource "aws_iam_role_policy" "ec2_session_manager" {
  name = "session-manager-core"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RegisterManagedInstance"
        Effect   = "Allow"
        Action   = "ssm:UpdateInstanceInformation"
        Resource = "*"
      },
      {
        Sid    = "OpenSessionManagerChannels"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "ec2_runtime_deployment" {
  name = "runtime-deployment-read"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "GetEcrAuthorizationToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PullDemoApiImage"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = aws_ecr_repository.demo_api.arn
      },
      {
        Sid    = "ReadDemoApplicationSecrets"
        Effect = "Allow"
        Action = "ssm:GetParameter"
        Resource = [
          aws_ssm_parameter.db_master_password.arn,
          aws_ssm_parameter.auth_jwt_secret.arn,
        ]
      },
    ]
  })
}

resource "aws_iam_role_policy" "ec2_origin_verification" {
  name = "origin-verification-read"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadOriginVerificationToken"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = aws_ssm_parameter.origin_verify_token.arn
      },
    ]
  })
}

resource "aws_iam_role_policy" "ec2_acme_dns_route53" {
  name = "acme-dns-route53"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DiscoverHostedZones"
        Effect   = "Allow"
        Action   = "route53:ListHostedZones"
        Resource = "*"
      },
      {
        Sid      = "PollDnsChange"
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:${data.aws_partition.current.partition}:route53:::change/*"
      },
      {
        Sid      = "ManageExactAcmeChallenge"
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = "arn:${data.aws_partition.current.partition}:route53:::hostedzone/${data.aws_route53_zone.demo_public.zone_id}"
        Condition = {
          "ForAllValues:StringEquals" = {
            "route53:ChangeResourceRecordSetsActions"               = ["UPSERT", "DELETE"]
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = [local.origin_acme_challenge_record]
            "route53:ChangeResourceRecordSetsRecordTypes"           = ["TXT"]
          }
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-ec2"
  role = aws_iam_role.ec2.name

  tags = {
    Name = "${local.name_prefix}-ec2"
  }
}
