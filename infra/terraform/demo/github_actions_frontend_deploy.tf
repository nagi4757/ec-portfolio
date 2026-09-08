locals {
  github_actions_oidc_url        = "https://token.actions.githubusercontent.com"
  github_frontend_deploy_subject = "repo:nagi4757/ec-portfolio:environment:demo-frontend"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url = local.github_actions_oidc_url

  client_id_list = ["sts.amazonaws.com"]

  tags = {
    Name = "${local.name_prefix}-github-actions"
  }
}

data "aws_iam_policy_document" "github_frontend_deploy_assume_role" {
  statement {
    sid     = "GitHubFrontendDeployment"
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
      values   = [local.github_frontend_deploy_subject]
    }
  }
}

resource "aws_iam_role" "github_frontend_deploy" {
  name                 = "ec-portfolio-demo-github-frontend-deploy"
  description          = "Upload reviewed Store and Admin artifacts from the protected GitHub environment"
  assume_role_policy   = data.aws_iam_policy_document.github_frontend_deploy_assume_role.json
  max_session_duration = 3600

  tags = {
    Name = "${local.name_prefix}-github-frontend-deploy"
  }
}

data "aws_iam_policy_document" "github_frontend_deploy" {
  statement {
    sid    = "ReadFrontendDeploymentObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
    ]
    resources = [
      "${aws_s3_bucket.frontend["store"].arn}/*",
      "${aws_s3_bucket.frontend["admin"].arn}/*",
    ]
  }

  statement {
    sid    = "WriteFrontendDeploymentObjects"
    effect = "Allow"
    actions = [
      "s3:PutObject",
    ]
    resources = [
      "${aws_s3_bucket.frontend["store"].arn}/*",
      "${aws_s3_bucket.frontend["admin"].arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "github_frontend_deploy" {
  name   = "frontend-artifact-deploy"
  role   = aws_iam_role.github_frontend_deploy.id
  policy = data.aws_iam_policy_document.github_frontend_deploy.json
}
