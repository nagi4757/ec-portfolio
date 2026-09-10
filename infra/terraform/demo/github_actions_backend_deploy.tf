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

# Phase 5F-2b: runtime deployment via SSM Run Command. Scoped to the single
# Demo instance and the AWS-owned AWS-RunShellScript document only. No
# ec2:StartInstances, no ssm:GetDocument/DescribeDocument, no ssm:CancelCommand.
#
# Last-known-good image contract, split across three policies:
#   - this policy grants no access to it at all;
#   - the Phase 5F-1 api-image-publish policy above keeps its read grant, which
#     the migration and rollback gate depends on;
#   - write stays exclusive to the EC2 instance role, so only the host that
#     actually completed a deployment can advance the rollback reference.
#
# The action list mirrors exactly what deploy-runtime.sh calls: nothing more.
data "aws_iam_policy_document" "github_backend_deploy_runtime" {
  statement {
    sid    = "SendRuntimeDeployCommand"
    effect = "Allow"
    actions = [
      "ssm:SendCommand",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:${local.aws_region}::document/AWS-RunShellScript",
      aws_instance.demo.arn,
    ]
  }

  statement {
    sid    = "InspectManagedInstanceStatus"
    effect = "Allow"
    actions = [
      "ssm:DescribeInstanceInformation",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadRuntimeCommandResult"
    effect = "Allow"
    actions = [
      "ssm:GetCommandInvocation",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_backend_deploy_runtime" {
  name   = "runtime-deploy-command"
  role   = aws_iam_role.github_backend_deploy.id
  policy = data.aws_iam_policy_document.github_backend_deploy_runtime.json
}
