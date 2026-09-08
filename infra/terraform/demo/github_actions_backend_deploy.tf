locals {
  github_backend_deploy_subject = "repo:nagi4757/ec-portfolio:environment:demo-backend"
}

data "aws_iam_policy_document" "github_backend_deploy_assume_role" {
  statement {
    sid     = "GitHubBackendPublication"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_backend_deploy_subject]
    }
  }
}

resource "aws_iam_role" "github_backend_deploy" {
  name                 = "ec-portfolio-demo-github-backend-deploy"
  description          = "Publish reviewed API images from the protected GitHub environment"
  assume_role_policy   = data.aws_iam_policy_document.github_backend_deploy_assume_role.json
  max_session_duration = 3600

  tags = {
    Name = "${local.name_prefix}-github-backend-deploy"
  }
}

data "aws_iam_policy_document" "github_backend_deploy" {
  statement {
    sid    = "GetEcrAuthorizationToken"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "InspectExistingApiImage"
    effect = "Allow"
    actions = [
      "ecr:DescribeImages",
    ]
    resources = [aws_ecr_repository.demo_api.arn]
  }

  statement {
    sid    = "PublishImmutableApiImage"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.demo_api.arn]
  }

  statement {
    sid    = "ReadDeploymentState"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
    ]
    resources = [
      aws_ssm_parameter.deploy_desired_image_sha.arn,
      aws_ssm_parameter.deploy_last_known_good_image_sha.arn,
      aws_ssm_parameter.deploy_pending_migration_image_sha.arn,
    ]
  }

  statement {
    sid    = "RecordDeploymentState"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
    ]
    resources = [
      aws_ssm_parameter.deploy_desired_image_sha.arn,
      aws_ssm_parameter.deploy_pending_migration_image_sha.arn,
    ]
  }
}

resource "aws_iam_role_policy" "github_backend_deploy" {
  name   = "api-image-publish"
  role   = aws_iam_role.github_backend_deploy.id
  policy = data.aws_iam_policy_document.github_backend_deploy.json
}
