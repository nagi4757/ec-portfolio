# Phase 6C-5c-1: the reads the Demo root's plans make on the Phase 6C-5c runtime
# orchestration: three Step Functions state machines, the DynamoDB control
# table, the orchestrator role and the failure notification rule and target.
# The schedules that start the state machines, the scheduler role and the SNS
# topic policy are read by statements that already exist.
#
# The action set was derived from the calls AWS provider 6.62 makes (resource
# Read functions, CustomizeDiff and the tag interceptor), mapped to IAM actions
# through the AWS service reference:
#   - aws_sfn_state_machine reads with DescribeStateMachine and
#     ListStateMachineVersions, and its tags through the interceptor
#     (ListTagsForResource); all three authorize on the exact state machine.
#   - Its CustomizeDiff calls ValidateStateMachineDefinition whenever the
#     definition changes, including on create, so every plan that adds or edits
#     a state machine needs it. The service reference lists no resource type for
#     it, so it can only take "*". It validates a document and touches no
#     resource.
#   - aws_dynamodb_table reads with DescribeTable, DescribeContinuousBackups and
#     DescribeTimeToLive, and its tags with ListTagsOfResource.
#   - aws_cloudwatch_event_rule reads with DescribeRule and its tags with
#     ListTagsForResource; aws_cloudwatch_event_target reads with
#     ListTargetsByRule. All three authorize on the exact rule.
#   - iam:GetRole and iam:GetRolePolicy are already allowed on "*" by the
#     baseline; only the two role-scoped policy lists are added for the new role.
#
# The names are fixed by this change; the Demo root must use exactly these:
# state machines ec-portfolio-demo-day-open, ec-portfolio-demo-ready-check and
# ec-portfolio-demo-day-close, table ec-portfolio-demo-runtime-control, role
# ec-portfolio-demo-runtime-orchestrator, rule
# ec-portfolio-demo-runtime-orchestration-failed on the default event bus.
data "aws_iam_policy_document" "plan_runtime_orchestration" {
  statement {
    sid    = "ReadExactRuntimeStateMachines"
    effect = "Allow"
    actions = [
      "states:DescribeStateMachine",
      "states:ListStateMachineVersions",
      "states:ListTagsForResource",
    ]
    resources = [
      "arn:aws:states:ap-northeast-1:${local.account_id}:stateMachine:ec-portfolio-demo-day-open",
      "arn:aws:states:ap-northeast-1:${local.account_id}:stateMachine:ec-portfolio-demo-ready-check",
      "arn:aws:states:ap-northeast-1:${local.account_id}:stateMachine:ec-portfolio-demo-day-close",
    ]
  }

  statement {
    sid    = "ValidateStateMachineDefinitions"
    effect = "Allow"
    actions = [
      "states:ValidateStateMachineDefinition",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "ReadExactRuntimeControlTable"
    effect = "Allow"
    actions = [
      "dynamodb:DescribeTable",
      "dynamodb:DescribeContinuousBackups",
      "dynamodb:DescribeTimeToLive",
      "dynamodb:ListTagsOfResource",
    ]
    resources = [
      "arn:aws:dynamodb:ap-northeast-1:${local.account_id}:table/ec-portfolio-demo-runtime-control",
    ]
  }

  statement {
    sid    = "ReadRuntimeOrchestratorRolePolicies"
    effect = "Allow"
    actions = [
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/ec-portfolio-demo-runtime-orchestrator",
    ]
  }

  statement {
    sid    = "ReadExactRuntimeFailureRule"
    effect = "Allow"
    actions = [
      "events:DescribeRule",
      "events:ListTargetsByRule",
      "events:ListTagsForResource",
    ]
    resources = [
      "arn:aws:events:ap-northeast-1:${local.account_id}:rule/ec-portfolio-demo-runtime-orchestration-failed",
    ]
  }
}
