# Guardrails over the rendered Plan and Apply inline policies.
#
# These are check blocks, which report without blocking, while the existing
# policies are being adopted. A violation in a policy that is already live must
# surface in review, not stop the no-op import that brings it under review.
# Once the adopted policies are cleaned up, these become lifecycle preconditions
# on the inline policy resources so that a violating change cannot be applied.

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
