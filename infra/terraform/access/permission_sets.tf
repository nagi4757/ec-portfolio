# The permission sets themselves are looked up, not managed. Their name, session
# duration, tags, policy attachments and account assignments stay under the
# Identity Center console. This root owns exactly one thing per permission set:
# its inline policy document.
#
# A lookup by name also fails closed: if a permission set is renamed or
# replaced, the plan stops here instead of writing a policy somewhere else.
data "aws_ssoadmin_permission_set" "plan" {
  instance_arn = local.instance_arn
  name         = local.plan_permission_set_name
}

data "aws_ssoadmin_permission_set" "apply" {
  instance_arn = local.instance_arn
  name         = local.apply_permission_set_name
}

# The resource owns the whole document: whatever the policy data source renders
# replaces the live policy on the next apply. That is why adoption is gated on
# the rendered document being semantically identical to the exported one.
resource "aws_ssoadmin_permission_set_inline_policy" "plan" {
  instance_arn       = local.instance_arn
  permission_set_arn = data.aws_ssoadmin_permission_set.plan.arn
  inline_policy      = data.aws_iam_policy_document.plan.json

  # Destroying this resource deletes the live policy. The access-admin
  # permission set is not granted sso:DeleteInlinePolicyFromPermissionSet
  # either, so a removal has to go through a removed block instead.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ssoadmin_permission_set_inline_policy" "apply" {
  instance_arn       = local.instance_arn
  permission_set_arn = data.aws_ssoadmin_permission_set.apply.arn
  inline_policy      = data.aws_iam_policy_document.apply.json

  # Identity Center updates one permission set per account at a time. Both
  # resources provision on every policy change, so they must not run together.
  depends_on = [aws_ssoadmin_permission_set_inline_policy.plan]

  lifecycle {
    prevent_destroy = true
  }
}
