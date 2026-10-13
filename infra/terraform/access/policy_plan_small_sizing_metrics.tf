# Phase 6C-5c small instance sizing. Before the Spot host can move from
# t3a.medium to a 2 GiB type, the operator needs the memory and CPU that the ECS
# task actually used on the Spot hosts that already ran. Those numbers exist only
# as the default AWS/ECS and AWS/EC2 CloudWatch metrics: Container Insights is
# disabled on the cluster and no CloudWatch agent runs on the hosts, and neither
# is turned on for this.
#
# The read-only sizing query makes one CloudWatch call, GetMetricData, with known
# namespaces, metric names and dimensions. It needs no other action:
#   - cloudwatch:GetMetricData has no resource-level permissions and no condition
#     key that narrows it to a namespace (AWS service reference), so the resource
#     is "*". The global aws:RequestedRegion condition keeps it to Tokyo, where
#     the Demo runs.
#   - cloudwatch:ListMetrics is not granted: the dimensions are known, and a
#     metric without data comes back as an empty result.
#   - cloudwatch:GetMetricStatistics, GetMetricWidgetImage and the alarm and
#     dashboard reads are not granted.
#
# The call returns metric values only, no log content and no configuration.
data "aws_iam_policy_document" "plan_small_sizing_metrics" {
  statement {
    sid    = "ReadCloudWatchMetricDataInTokyo"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-1"]
    }
  }
}
