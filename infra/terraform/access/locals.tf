locals {
  # The Identity Center instance lives in this region.
  aws_region = "ap-northeast-1"

  # The only identity allowed to run this root. It is the manually managed
  # ECPortfolioAccessAdmin permission set, never the Plan, Apply or Bootstrap
  # permission sets whose policies this root owns.
  access_admin_session_pattern = "^arn:aws:sts::[0-9]{12}:assumed-role/AWSReservedSSO_ECPortfolioAccessAdmin_[0-9a-f]+/[^/]+$"

  plan_permission_set_name  = "ECPortfolioTerraformPlan"
  apply_permission_set_name = "ECPortfolioTerraformApply"
}
