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

    # Fail-closed guardrail (policy_guardrails.tf): from the Phase 6C-5c runtime
    # orchestration services the Plan inline policy names only the exact reads
    # its plans make.
    precondition {
      condition     = length(local.runtime_orchestration_inline_grants.plan) == 0
      error_message = "The Plan inline policy grants a Step Functions, DynamoDB, EventBridge or EventBridge Scheduler action outside its read allowlist (by name, through a wildcard or through Allow with NotAction) in statement(s) ${join(", ", local.runtime_orchestration_inline_grants.plan)}."
    }
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

    # Fail-closed guardrail (policy_guardrails.tf): the origin Elastic IP is
    # associated only through the customer managed policy
    # ECPortfolioOriginEipAssociation, never through this inline policy.
    precondition {
      condition     = length(local.apply_inline_eip_association_grants) == 0
      error_message = "The Apply inline policy grants ec2:AssociateAddress or ec2:DisassociateAddress (by name, through a wildcard or through Allow with NotAction) in statement(s) ${join(", ", local.apply_inline_eip_association_grants)}. Origin EIP association belongs only to the customer managed policy ECPortfolioOriginEipAssociation."
    }

    # Fail-closed guardrail (policy_guardrails.tf): the Phase 6C-5c runtime
    # orchestration is written only through the customer managed policy
    # ECPortfolioTerraformApplyRuntimeOrchestration, never through this inline
    # policy.
    precondition {
      condition     = length(local.runtime_orchestration_inline_grants.apply) == 0
      error_message = "The Apply inline policy grants a Step Functions, DynamoDB or EventBridge action, or an EventBridge Scheduler action it did not have (by name, through a wildcard or through Allow with NotAction) in statement(s) ${join(", ", local.runtime_orchestration_inline_grants.apply)}. The runtime orchestration belongs only to the customer managed policy ECPortfolioTerraformApplyRuntimeOrchestration."
    }
  }
}
