# The two command documents the cold standby runs on its hosts (design 2.2,
# 2.3). Readiness and protected end-to-end checks; no association runs them.
# Only the orchestrator can send these exact documents to the approved hosts.
#
# `permissions` stays unset: setting it shares a document with other accounts
# and needs ssm:ModifyDocumentPermission, which the Access IaC does not grant.
resource "aws_ssm_document" "od_readiness" {
  name            = "${local.name_prefix}-od-readiness"
  document_type   = "Command"
  document_format = "YAML"
  content         = file("${path.module}/ssm-documents/od-readiness.yaml")

  tags = {
    Name = "${local.name_prefix}-od-readiness"
  }
}

resource "aws_ssm_document" "spot_smoke" {
  name            = "${local.name_prefix}-spot-smoke"
  document_type   = "Command"
  document_format = "YAML"
  content         = file("${path.module}/ssm-documents/spot-smoke.yaml")

  tags = {
    Name = "${local.name_prefix}-spot-smoke"
  }
}
