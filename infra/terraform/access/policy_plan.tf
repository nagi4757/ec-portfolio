# The ECPortfolioTerraformPlan inline policy: the adopted baseline, followed by
# one document per later, separately reviewed change.
data "aws_iam_policy_document" "plan" {
  source_policy_documents = [
    data.aws_iam_policy_document.plan_baseline.json,
    data.aws_iam_policy_document.plan_origin_tls.json,
  ]
}

# The inline policy as adopted, reproduced statement for statement from the
# Identity Center export (canonical sha256
# 305cf843bf627cf9dff70bbfc6b4f1879416b3c81e4151d99bc873d6bb351f78).
#
# Statement order, Sids and action order follow the export so that the adoption
# plan was a pure import. New permissions go into their own documents above,
# never into this one.
data "aws_iam_policy_document" "plan_baseline" {
  statement {
    sid    = "CallerIdentity"
    effect = "Allow"
    actions = [
      "sts:GetCallerIdentity",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "TerraformStateBucketMetadata"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::ec-portfolio-terraform-state-${local.account_id}-ap-northeast-1",
    ]
  }

  statement {
    sid    = "TerraformDemoStateReadOnly"
    effect = "Allow"
    actions = [
      "s3:GetObject",
    ]
    resources = [
      "arn:aws:s3:::ec-portfolio-terraform-state-${local.account_id}-ap-northeast-1/demo/terraform.tfstate",
    ]
  }

  statement {
    sid    = "TerraformDemoStateLock"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:aws:s3:::ec-portfolio-terraform-state-${local.account_id}-ap-northeast-1/demo/terraform.tfstate.tflock",
    ]
  }

  statement {
    sid    = "ReadExistingDemoNetwork"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "ec2:GetManagedPrefixListEntries",
    ]
    resources = [
      "*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values = [
        "ap-northeast-1",
      ]
    }
  }

  statement {
    sid    = "ReadAmazonLinux2023PublicAmi"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
    ]
    resources = [
      "arn:aws:ssm:ap-northeast-1::parameter/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeAddresses",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceCreditSpecifications",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeManagedPrefixLists",
      "ec2:GetManagedPrefixListEntries",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSecurityGroupRules",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "rds:DescribeDBInstances",
      "rds:DescribeDBSubnetGroups",
      "rds:ListTagsForResource",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:GetInstanceProfile",
      "iam:ListRoleTags",
      "iam:ListInstanceProfileTags",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "scheduler:GetSchedule",
      "scheduler:GetScheduleGroup",
      "scheduler:ListTagsForResource",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "sns:GetTopicAttributes",
      "sns:GetSubscriptionAttributes",
      "sns:ListSubscriptionsByTopic",
      "sns:ListTagsForResource",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "cloudwatch:DescribeAlarms",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
    ]
    resources = [
      "arn:aws:ssm:ap-northeast-1::parameter/aws/service/ami-amazon-linux-latest/*",
      "arn:aws:ssm:ap-northeast-1:${local.account_id}:parameter/ec-portfolio/demo/*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:DescribeRepositories",
      "ecr:GetLifecyclePolicy",
      "ecr:ListTagsForResource",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "ReadDemoAlarmTags"
    effect = "Allow"
    actions = [
      "cloudwatch:ListTagsForResource",
    ]
    resources = [
      "arn:aws:cloudwatch:ap-northeast-1:${local.account_id}:alarm:ec-portfolio-demo-scheduler-invocation-dropped",
    ]
  }

  statement {
    sid    = "ReadDemoBudget"
    effect = "Allow"
    actions = [
      "budgets:ViewBudget",
    ]
    resources = [
      "arn:aws:budgets::${local.account_id}:budget/ec-portfolio-demo-monthly-cost",
    ]
  }

  statement {
    sid    = "ReadDemoRolePolicyInventory"
    effect = "Allow"
    actions = [
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/ec-portfolio-demo-ec2",
      "arn:aws:iam::${local.account_id}:role/ec-portfolio-demo-scheduler",
    ]
  }

  statement {
    sid    = "DescribeParameterMetadata"
    effect = "Allow"
    actions = [
      "ssm:DescribeParameters",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "ReadDemoBudgetTags"
    effect = "Allow"
    actions = [
      "budgets:ListTagsForResource",
    ]
    resources = [
      "arn:aws:budgets::${local.account_id}:budget/ec-portfolio-demo-monthly-cost",
    ]
  }

  statement {
    sid    = "ReadDemoParameterTags"
    effect = "Allow"
    actions = [
      "ssm:ListTagsForResource",
    ]
    resources = [
      "arn:aws:ssm:ap-northeast-1:${local.account_id}:parameter/ec-portfolio/demo/db/master-password",
      "arn:aws:ssm:ap-northeast-1:${local.account_id}:parameter/ec-portfolio/demo/app/auth-jwt-secret",
    ]
  }

  statement {
    sid    = "ReadRoute53HostedZones"
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "ReadExactRoute53HostedZone"
    effect = "Allow"
    actions = [
      "route53:GetHostedZone",
    ]
    resources = [
      "arn:aws:route53:::hostedzone/Z04824291CGNXBGU98Q85",
    ]
  }

  statement {
    sid    = "ReadExactRoute53HostedZoneTags"
    effect = "Allow"
    actions = [
      "route53:ListTagsForResource",
    ]
    resources = [
      "arn:aws:route53:::hostedzone/Z04824291CGNXBGU98Q85",
    ]
  }

  statement {
    sid    = "ReadExactOriginDnsRecordSets"
    effect = "Allow"
    actions = [
      "route53:ListResourceRecordSets",
    ]
    resources = [
      "arn:aws:route53:::hostedzone/Z04824291CGNXBGU98Q85",
    ]
  }

  statement {
    sid    = "ReadExactOriginParameterTags"
    effect = "Allow"
    actions = [
      "ssm:ListTagsForResource",
    ]
    resources = [
      "arn:aws:ssm:ap-northeast-1:${local.account_id}:parameter/ec-portfolio/demo/origin/verify-token",
    ]
  }

  statement {
    sid    = "ReadManagedCloudFrontCachePolicy"
    effect = "Allow"
    actions = [
      "cloudfront:GetCachePolicy",
    ]
    resources = [
      "arn:aws:cloudfront::${local.account_id}:cache-policy/4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
    ]
  }

  statement {
    sid    = "ReadExactOriginRequestPolicy"
    effect = "Allow"
    actions = [
      "cloudfront:GetOriginRequestPolicy",
    ]
    resources = [
      "arn:aws:cloudfront::${local.account_id}:origin-request-policy/807d4dff-0d7b-44ca-9770-2063ac951fe7",
    ]
  }

  statement {
    sid    = "ReadExactDemoCloudFrontDistribution"
    effect = "Allow"
    actions = [
      "cloudfront:GetDistribution",
    ]
    resources = [
      "arn:aws:cloudfront::${local.account_id}:distribution/E1PAO1JFLRFDSN",
    ]
  }

  statement {
    sid    = "ReadExactDemoCloudFrontDistributionTags"
    effect = "Allow"
    actions = [
      "cloudfront:ListTagsForResource",
    ]
    resources = [
      "arn:aws:cloudfront::${local.account_id}:distribution/E1PAO1JFLRFDSN",
    ]
  }

  statement {
    sid    = "ReadCloudFrontDistributionTags"
    effect = "Allow"
    actions = [
      "cloudfront:ListTagsForResource",
    ]
    resources = [
      "arn:aws:cloudfront::${local.account_id}:distribution/E1PAO1JFLRFDSN",
    ]
  }
}
