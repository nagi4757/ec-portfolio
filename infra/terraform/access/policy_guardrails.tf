# Guardrails over the rendered Plan and Apply inline policies.
#
# The general guardrails are check blocks, which report without blocking, while
# the existing policies are being adopted. A violation in a policy that is
# already live must surface in review, not stop the no-op import that brings it
# under review. Once the adopted policies are cleaned up, these become lifecycle
# preconditions on the inline policy resources so that a violating change cannot
# be applied. The Phase 6C-5 D3 guardrail at the end of this file is already one.

locals {
  rendered_inline_policies = {
    plan  = data.aws_iam_policy_document.plan.json
    apply = data.aws_iam_policy_document.apply.json
  }

  # Identity Center accepts at most 10,240 non-whitespace characters per inline
  # policy (32,768 bytes including whitespace).
  inline_policy_max_non_whitespace_characters = 10240

  allow_statements = flatten([
    for policy in values(local.rendered_inline_policies) : [
      for statement in jsondecode(policy).Statement : statement if statement.Effect == "Allow"
    ]
  ])

  # Action is a string when the list has one element. A statement without
  # Action uses NotAction, which is covered by its own check.
  allow_actions = flatten([
    for statement in local.allow_statements : try(tolist(statement.Action), [try(statement.Action, "")])
  ])
}

check "inline_policy_size" {
  assert {
    condition = alltrue([
      for policy in values(local.rendered_inline_policies) :
      length(replace(policy, "/\\s/", "")) <= local.inline_policy_max_non_whitespace_characters
    ])
    error_message = "An inline policy exceeds the Identity Center limit of 10,240 non-whitespace characters."
  }
}

check "no_whole_service_allow" {
  assert {
    condition = alltrue([
      for action in local.allow_actions : !can(regex("^(\\*|[A-Za-z0-9-]+:\\*)$", action))
    ])
    error_message = "An inline policy allows every action of a service (or of every service)."
  }
}

check "no_allow_with_not_action" {
  assert {
    condition = alltrue([
      for statement in local.allow_statements : !can(statement.NotAction)
    ])
    error_message = "An inline policy combines Allow with NotAction, which grants everything not listed."
  }
}

# Plan and Apply must never be able to change who holds which permissions.
# Identity Center and Organizations are administered only through this root,
# running as the access-admin permission set.
check "no_identity_administration" {
  assert {
    condition = alltrue([
      for action in local.allow_actions :
      !can(regex("(?i)^(sso|sso-directory|identitystore|organizations):", action))
    ])
    error_message = "A Plan or Apply inline policy grants an Identity Center, identity store or Organizations action."
  }
}

# Phase 6C-5 D3: the Apply permission set associates the origin Elastic IP only
# through the customer managed policy ECPortfolioOriginEipAssociation (exact
# address, On-Demand host or Spot hosts; see README). Its inline policy must not
# grant ec2:AssociateAddress again, nor ec2:DisassociateAddress at all: not by
# name, not through a wildcard, not through an Allow with NotAction. An action
# with characters outside an IAM action name is refused too, so a pattern that
# cannot be matched fails instead of passing. The customer managed policy lives
# outside this root and is not checked here.
#
# Unlike the check blocks above, this guardrail fails closed: it is a
# lifecycle precondition on aws_ssoadmin_permission_set_inline_policy.apply
# (permission_sets.tf), so a violating document stops the plan and the apply
# and is never written to the permission set. The locals below are its
# condition: the Sids of the Allow statements that grant a forbidden action.
locals {
  apply_inline_forbidden_actions = ["ec2:AssociateAddress", "ec2:DisassociateAddress"]

  apply_inline_eip_association_grants = [
    for statement in jsondecode(data.aws_iam_policy_document.apply.json).Statement :
    try(statement.Sid, "(statement without Sid)")
    if statement.Effect == "Allow" && (can(statement.NotAction) || anytrue([
      for action in try(tolist(statement.Action), [try(statement.Action, "")]) :
      !can(regex("^[A-Za-z0-9:*?_-]+$", action)) || anytrue([
        for forbidden in local.apply_inline_forbidden_actions :
        can(regex(format("(?i)^%s$", replace(replace(action, "*", ".*"), "?", ".")), forbidden))
      ])
    ]))
  ]
}
