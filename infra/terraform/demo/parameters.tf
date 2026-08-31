resource "aws_ssm_parameter" "db_master_password" {
  name        = "/ec-portfolio/demo/db/master-password"
  description = "Demo MariaDB master password for approved runtime provisioning"
  type        = "SecureString"
  tier        = "Standard"
  key_id      = "alias/aws/ssm"

  value_wo         = var.db_master_password
  value_wo_version = var.db_master_password_version

  tags = {
    Name = "${local.name_prefix}-db-master-password"
  }
}
