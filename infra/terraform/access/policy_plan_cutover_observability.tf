# Phase 6C-5b-2 cutover observability. Before the first traffic cutover the
# operator must prove that a request sent through CloudFront was served by the
# Spot host. The API logs every request with its X-Correlation-ID, and only the
# ECS tasks on the Spot host ship their logs to /ec-portfolio/demo/ecs/api (the
# On-Demand host logs locally), so one lookup of a known ID in that log group
# answers the question.
#
# The read-only cutover observer makes exactly one Logs call for this,
# FilterLogEvents with a filter pattern on the ID. It needs no other Logs action:
#   - logs:FilterLogEvents authorizes on the log-group resource type, in the
#     standard ARN format without ":*" (AWS service reference; CloudWatch Logs
#     identity-based policy examples). It has no dependent action.
#   - logs:GetLogEvents and logs:DescribeLogStreams are not called, so they are
#     not granted.
#   - logs:DescribeLogGroups is not called by the observer; the existing grant
#     in policy_plan_ecs_application.tf serves the Terraform refresh only.
#   - The log group has no KMS key, so no kms:Decrypt is needed.
#
# The name is fixed by the Phase 6C-4 design; the Demo root must keep exactly
# this log group: /ec-portfolio/demo/ecs/api.
data "aws_iam_policy_document" "plan_cutover_observability" {
  statement {
    sid    = "FilterExactEcsApiLogGroupEvents"
    effect = "Allow"
    actions = [
      "logs:FilterLogEvents",
    ]
    resources = [
      "arn:aws:logs:ap-northeast-1:${local.account_id}:log-group:/ec-portfolio/demo/ecs/api",
    ]
  }
}
