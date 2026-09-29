# Phase 6C-4 adds the ECS application layer to the Demo root: the API log group,
# the task execution role and its three inline policies, the API task definition
# and the API service (DAEMON, launch type EC2, no load balancer, no task role).
# These are the reads the post-apply convergence plan makes on them.
#
# The action set was derived from the refresh calls of AWS provider 6.62
# (resource Read functions and the tag interceptor), mapped to IAM actions
# through the AWS service reference. It is not a guess from resource names:
#   - ecs:DescribeTaskDefinition and logs:DescribeLogGroups have no resource
#     type in the service reference, so they can only take "*".
#   - ecs:DescribeServices has one, and is granted on the exact service ARN.
#   - The task definition and service reads return their tags (Include TAGS),
#     so no ecs:ListTagsForResource is needed.
#   - The log group read sets no tags, so the tag interceptor lists them:
#     logs:ListTagsForResource on the exact log group.
#   - iam:GetRole and iam:GetRolePolicy on the task execution role are already
#     allowed by the baseline statement on "*"; only the two policy lists are
#     role-scoped and are added here for the new role.
#
# The names are fixed by the Phase 6C-4 design; the Demo root must use exactly
# these: log group /ec-portfolio/demo/ecs/api, role
# ec-portfolio-demo-ecs-task-execution, service ec-portfolio-demo-api in the
# ec-portfolio-demo cluster.
data "aws_iam_policy_document" "plan_ecs_application" {
  statement {
    sid    = "ReadEcsApiTaskDefinitions"
    effect = "Allow"
    actions = [
      "ecs:DescribeTaskDefinition",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "ReadExactEcsApiService"
    effect = "Allow"
    actions = [
      "ecs:DescribeServices",
    ]
    resources = [
      "arn:aws:ecs:ap-northeast-1:${local.account_id}:service/ec-portfolio-demo/ec-portfolio-demo-api",
    ]
  }

  statement {
    sid    = "DescribeLogGroupsForEcsApi"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "ReadExactEcsApiLogGroupTags"
    effect = "Allow"
    actions = [
      "logs:ListTagsForResource",
    ]
    resources = [
      "arn:aws:logs:ap-northeast-1:${local.account_id}:log-group:/ec-portfolio/demo/ecs/api",
      "arn:aws:logs:ap-northeast-1:${local.account_id}:log-group:/ec-portfolio/demo/ecs/api:*",
    ]
  }

  statement {
    sid    = "ReadEcsTaskExecutionRolePolicyLists"
    effect = "Allow"
    actions = [
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/ec-portfolio-demo-ecs-task-execution",
    ]
  }
}
