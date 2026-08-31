resource "aws_db_subnet_group" "demo" {
  name = "${local.name_prefix}-db"
  subnet_ids = [
    aws_subnet.private_db["a"].id,
    aws_subnet.private_db["b"].id,
  ]

  tags = {
    Name = "${local.name_prefix}-db"
  }
}

resource "aws_db_instance" "demo" {
  identifier = "${local.name_prefix}-mariadb"

  engine                      = "mariadb"
  engine_version              = "10.11"
  instance_class              = "db.t4g.micro"
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name                         = "ecportfolio"
  username                        = "ecadmin"
  password_wo                     = var.db_master_password
  password_wo_version             = var.db_master_password_version
  port                            = 3306
  network_type                    = "IPV4"
  db_subnet_group_name            = aws_db_subnet_group.demo.name
  vpc_security_group_ids          = [aws_security_group.rds.id]
  publicly_accessible             = false
  multi_az                        = false
  backup_retention_period         = 1
  deletion_protection             = true
  skip_final_snapshot             = true
  performance_insights_enabled    = false
  monitoring_interval             = 0
  enabled_cloudwatch_logs_exports = []

  tags = {
    Name     = "${local.name_prefix}-mariadb"
    AutoStop = "true"
  }
}
