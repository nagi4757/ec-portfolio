# The ECPortfolioTerraformApply inline policy, reproduced statement for statement from the
# Identity Center export it is adopted from (canonical sha256
# d4c7c0f73994e1770f017d9e3cdd5ed638676e63ae4a45ff066d1b0580d1137d).
#
# Statement order, Sids and action order follow the export so that the adoption
# plan is a pure import. Restructuring and new permissions belong in later,
# separately reviewed changes.

data "aws_iam_policy_document" "apply" {
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
    sid    = "TerraformStateReadWrite"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = [
      "arn:aws:s3:::ec-portfolio-terraform-state-${local.account_id}-ap-northeast-1/demo/terraform.tfstate",
    ]
  }

  statement {
    sid    = "TerraformStateLock"
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
    sid    = "Ec2DemoApply"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "ec2:GetManagedPrefixListEntries",
      "ec2:RunInstances",
      "ec2:AllocateAddress",
      "ec2:AssociateAddress",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:ModifyInstanceCreditSpecification",
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
    sid    = "IamDemoRead"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:GetInstanceProfile",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRoleTags",
      "iam:ListInstanceProfileTags",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/ec-portfolio-demo-ec2",
      "arn:aws:iam::${local.account_id}:role/ec-portfolio-demo-scheduler",
      "arn:aws:iam::${local.account_id}:instance-profile/ec-portfolio-demo-ec2",
    ]
  }

  statement {
    sid    = "IamDemoList"
    effect = "Allow"
    actions = [
      "iam:ListInstanceProfiles",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "IamDemoCreate"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:TagRole",
      "iam:PutRolePolicy",
      "iam:CreateInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:AddRoleToInstanceProfile",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/ec-portfolio-demo-ec2",
      "arn:aws:iam::${local.account_id}:role/ec-portfolio-demo-scheduler",
      "arn:aws:iam::${local.account_id}:instance-profile/ec-portfolio-demo-ec2",
    ]
  }

  statement {
    sid    = "PassEc2Role"
    effect = "Allow"
    actions = [
      "iam:PassRole",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/ec-portfolio-demo-ec2",
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "ec2.amazonaws.com",
      ]
    }
  }

  statement {
    sid    = "PassSchedulerRole"
    effect = "Allow"
    actions = [
      "iam:PassRole",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/ec-portfolio-demo-scheduler",
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "scheduler.amazonaws.com",
      ]
    }
  }

  statement {
    sid    = "CreateRdsServiceLinkedRoleIfRequired"
    effect = "Allow"
    actions = [
      "iam:CreateServiceLinkedRole",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/aws-service-role/rds.amazonaws.com/AWSServiceRoleForRDS",
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "rds.amazonaws.com",
      ]
    }
  }

  statement {
    sid    = "RdsDemoApply"
    effect = "Allow"
    actions = [
      "rds:Describe*",
      "rds:ListTagsForResource",
      "rds:CreateDBSubnetGroup",
      "rds:CreateDBInstance",
      "rds:AddTagsToResource",
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
    sid    = "ReadAmazonLinuxPublicAmi"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
    ]
    resources = [
      "arn:aws:ssm:ap-northeast-1::parameter/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64",
    ]
  }

  statement {
    sid    = "DemoDbParameter"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
      "ssm:GetParameter",
      "ssm:AddTagsToResource",
      "ssm:ListTagsForResource",
    ]
    resources = [
      "arn:aws:ssm:ap-northeast-1:${local.account_id}:parameter/ec-portfolio/demo/db/master-password",
    ]
  }

  statement {
    sid    = "DescribeSsmParameters"
    effect = "Allow"
    actions = [
      "ssm:DescribeParameters",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "SsmSecureStringKms"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
    ]
    resources = [
      "*",
    ]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "ssm.ap-northeast-1.amazonaws.com",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values = [
        "${local.account_id}",
      ]
    }
  }

  statement {
    sid    = "SchedulerList"
    effect = "Allow"
    actions = [
      "scheduler:ListSchedules",
      "scheduler:ListScheduleGroups",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "SchedulerGroupApply"
    effect = "Allow"
    actions = [
      "scheduler:CreateScheduleGroup",
      "scheduler:GetScheduleGroup",
      "scheduler:ListTagsForResource",
      "scheduler:TagResource",
    ]
    resources = [
      "arn:aws:scheduler:ap-northeast-1:${local.account_id}:schedule-group/ec-portfolio-demo-runtime",
    ]
  }

  statement {
    sid    = "SchedulerApply"
    effect = "Allow"
    actions = [
      "scheduler:CreateSchedule",
      "scheduler:GetSchedule",
    ]
    resources = [
      "arn:aws:scheduler:ap-northeast-1:${local.account_id}:schedule/ec-portfolio-demo-runtime/ec-portfolio-demo-*",
    ]
  }

  statement {
    sid    = "SnsDemoApply"
    effect = "Allow"
    actions = [
      "sns:GetTopicAttributes",
      "sns:GetSubscriptionAttributes",
      "sns:ListSubscriptionsByTopic",
      "sns:ListTagsForResource",
      "sns:CreateTopic",
      "sns:TagResource",
      "sns:SetTopicAttributes",
      "sns:Subscribe",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "CloudWatchDemoApply"
    effect = "Allow"
    actions = [
      "cloudwatch:DescribeAlarms",
      "cloudwatch:ListTagsForResource",
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:TagResource",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "BudgetDemo"
    effect = "Allow"
    actions = [
      "budgets:ViewBudget",
      "budgets:ModifyBudget",
      "budgets:TagResource",
      "budgets:ListTagsForResource",
    ]
    resources = [
      "arn:aws:budgets::${local.account_id}:budget/ec-portfolio-demo-monthly-cost",
    ]
  }

  statement {
    sid    = "BudgetLegacyDependency"
    effect = "Allow"
    actions = [
      "aws-portal:ViewBilling",
      "aws-portal:ModifyBilling",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "ManageDemoApiEcr"
    effect = "Allow"
    actions = [
      "ecr:CreateRepository",
      "ecr:TagResource",
      "ecr:DescribeRepositories",
      "ecr:ListTagsForResource",
      "ecr:PutLifecyclePolicy",
      "ecr:GetLifecyclePolicy",
    ]
    resources = [
      "arn:aws:ecr:ap-northeast-1:${local.account_id}:repository/ec-portfolio-demo-api",
    ]
  }

  statement {
    sid    = "ManageDemoJwtParameter"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
      "ssm:GetParameter",
      "ssm:AddTagsToResource",
      "ssm:ListTagsForResource",
    ]
    resources = [
      "arn:aws:ssm:ap-northeast-1:${local.account_id}:parameter/ec-portfolio/demo/app/auth-jwt-secret",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "ssm:DescribeParameters",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "ManageEc2RuntimeInlinePolicy"
    effect = "Allow"
    actions = [
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/ec-portfolio-demo-ec2",
    ]
  }

  statement {
    sid    = "ReadYoonecHostedZoneForApply"
    effect = "Allow"
    actions = [
      "route53:GetHostedZone",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]
    resources = [
      "arn:aws:route53:::hostedzone/Z04824291CGNXBGU98Q85",
    ]
  }

  statement {
    sid    = "DiscoverHostedZoneForApply"
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "ManageExactOriginARecord"
    effect = "Allow"
    actions = [
      "route53:ChangeResourceRecordSets",
    ]
    resources = [
      "arn:aws:route53:::hostedzone/Z04824291CGNXBGU98Q85",
    ]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values = [
        "origin-demo.yoonec.dev",
      ]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values = [
        "A",
      ]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsActions"
      values = [
        "CREATE",
        "UPSERT",
      ]
    }
  }

  statement {
    sid    = "ReadRoute53ChangeStatus"
    effect = "Allow"
    actions = [
      "route53:GetChange",
    ]
    resources = [
      "arn:aws:route53:::change/*",
    ]
  }

  statement {
    sid    = "ManageOriginVerifyParameter"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
      "ssm:GetParameter",
      "ssm:AddTagsToResource",
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
    sid    = "CreateDemoCloudFrontResources"
    effect = "Allow"
    actions = [
      "cloudfront:CreateOriginRequestPolicy",
      "cloudfront:CreateDistribution",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "ReadDemoOriginRequestPolicies"
    effect = "Allow"
    actions = [
      "cloudfront:GetOriginRequestPolicy",
      "cloudfront:GetOriginRequestPolicyConfig",
    ]
    resources = [
      "arn:aws:cloudfront::${local.account_id}:origin-request-policy/*",
    ]
  }

  statement {
    sid    = "ReadDemoCloudFrontDistributions"
    effect = "Allow"
    actions = [
      "cloudfront:GetDistribution",
      "cloudfront:GetDistributionConfig",
    ]
    resources = [
      "arn:aws:cloudfront::${local.account_id}:distribution/*",
    ]
  }

  statement {
    sid    = "ManageDemoCloudFrontDistributionTags"
    effect = "Allow"
    actions = [
      "cloudfront:TagResource",
      "cloudfront:ListTagsForResource",
    ]
    resources = [
      "arn:aws:cloudfront::${local.account_id}:distribution/*",
    ]
  }

  statement {
    sid    = "UpdateExactDemoOriginRequestPolicy"
    effect = "Allow"
    actions = [
      "cloudfront:UpdateOriginRequestPolicy",
    ]
    resources = [
      "arn:aws:cloudfront::${local.account_id}:origin-request-policy/807d4dff-0d7b-44ca-9770-2063ac951fe7",
    ]
  }

  statement {
    sid    = "P5ABucketCreate"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
    ]
    resources = [
      "arn:aws:s3:::ec-portfolio-demo-store-*",
      "arn:aws:s3:::ec-portfolio-demo-admin-*",
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:locationconstraint"
      values = [
        "ap-northeast-1",
      ]
    }
  }

  statement {
    sid    = "P5ABucketConfigure"
    effect = "Allow"
    actions = [
      "s3:TagResource",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketOwnershipControls",
      "s3:PutEncryptionConfiguration",
      "s3:PutBucketPolicy",
    ]
    resources = [
      "arn:aws:s3:::ec-portfolio-demo-store-*",
      "arn:aws:s3:::ec-portfolio-demo-admin-*",
    ]
  }

  statement {
    sid    = "P5ABucketRead"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketPolicy",
      "s3:GetBucketAcl",
      "s3:GetBucketCORS",
      "s3:GetBucketWebsite",
      "s3:GetBucketVersioning",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketLogging",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketOwnershipControls",
      "s3:ListTagsForResource",
    ]
    resources = [
      "arn:aws:s3:::ec-portfolio-demo-store-*",
      "arn:aws:s3:::ec-portfolio-demo-admin-*",
    ]
  }

  statement {
    sid    = "P5AGlobalCreates"
    effect = "Allow"
    actions = [
      "cloudfront:CreateOriginAccessControl",
      "cloudfront:CreateCachePolicy",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "P5AFunctionCreate"
    effect = "Allow"
    actions = [
      "cloudfront:CreateFunction",
    ]
    resources = [
      "*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values = [
        "ec-portfolio",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Environment"
      values = [
        "demo",
      ]
    }
  }

  statement {
    sid    = "P5AOACBootstrapRead"
    effect = "Allow"
    actions = [
      "cloudfront:GetOriginAccessControl",
    ]
    resources = [
      "arn:aws:cloudfront::${local.account_id}:origin-access-control/*",
    ]
  }

  statement {
    sid    = "P5ACacheBootstrapRead"
    effect = "Allow"
    actions = [
      "cloudfront:GetCachePolicy",
    ]
    resources = [
      "arn:aws:cloudfront::${local.account_id}:cache-policy/*",
    ]
  }

  statement {
    sid    = "P5AFunctionReadPublishTag"
    effect = "Allow"
    actions = [
      "cloudfront:DescribeFunction",
      "cloudfront:GetFunction",
      "cloudfront:PublishFunction",
      "cloudfront:TagResource",
      "cloudfront:ListTagsForResource",
    ]
    resources = [
      "arn:aws:cloudfront::${local.account_id}:function/ec-portfolio-demo-frontend-spa-rewrite",
    ]
  }
}
