data "aws_caller_identity" "current" {}

# Every Identity Center read in this root depends on the instance lookup, so the
# identity check here runs before any of them. Running the root with the Plan,
# Apply or Bootstrap profile fails with this message instead of an AccessDenied
# part-way through a plan, and keeps failing even if one of those permission
# sets is ever granted Identity Center access by mistake.
data "aws_ssoadmin_instances" "this" {
  lifecycle {
    precondition {
      condition     = can(regex(local.access_admin_session_pattern, data.aws_caller_identity.current.arn))
      error_message = "The access root must run only as the ECPortfolioAccessAdmin permission set."
    }
  }
}

locals {
  instance_arn = one(data.aws_ssoadmin_instances.this.arns)

  # The account the Plan and Apply permission sets are provisioned to. The
  # discovery verifies it is also the account the access-admin runs in and the
  # owner of the Identity Center instance, so the caller's account is used
  # instead of a hard-coded ID.
  account_id = data.aws_caller_identity.current.account_id
}
