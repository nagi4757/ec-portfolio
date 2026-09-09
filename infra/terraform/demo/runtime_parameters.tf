locals {
  runtime_parameter_prefix = "/ec-portfolio/demo/runtime"

  # Phase 5C CORS contract. The two loopback origins are the Store and Admin Vite
  # dev servers; the two CloudFront origins are derived from the applied Phase 5A
  # distributions so a domain can never drift out of this allowlist. Reducing this
  # list to the CloudFront origins alone would break the Phase 5C contract.
  runtime_cors_allowed_origins = [
    "http://127.0.0.1:5174",
    "http://127.0.0.1:5173",
    "https://${aws_cloudfront_distribution.frontend["store"].domain_name}",
    "https://${aws_cloudfront_distribution.frontend["admin"].domain_name}",
  ]
}

resource "aws_ssm_parameter" "runtime_db_host" {
  name            = "${local.runtime_parameter_prefix}/db-host"
  description     = "Private endpoint of the Demo MariaDB instance. Not a secret."
  type            = "String"
  tier            = "Standard"
  allowed_pattern = "^[A-Za-z0-9.-]{1,255}$"
  value           = aws_db_instance.demo.address

  tags = {
    Name = "${local.name_prefix}-runtime-db-host"
  }
}

resource "aws_ssm_parameter" "runtime_db_port" {
  name            = "${local.runtime_parameter_prefix}/db-port"
  description     = "TCP port of the Demo MariaDB instance. Not a secret."
  type            = "String"
  tier            = "Standard"
  allowed_pattern = "^[0-9]{1,5}$"
  value           = tostring(aws_db_instance.demo.port)

  tags = {
    Name = "${local.name_prefix}-runtime-db-port"
  }
}

resource "aws_ssm_parameter" "runtime_db_name" {
  name            = "${local.runtime_parameter_prefix}/db-name"
  description     = "Database name used by the Demo API runtime. Not a secret."
  type            = "String"
  tier            = "Standard"
  allowed_pattern = "^[A-Za-z0-9_]{1,64}$"
  value           = aws_db_instance.demo.db_name

  tags = {
    Name = "${local.name_prefix}-runtime-db-name"
  }
}

resource "aws_ssm_parameter" "runtime_db_username" {
  name            = "${local.runtime_parameter_prefix}/db-username"
  description     = "Database username used by the Demo API runtime. The password stays a SecureString."
  type            = "String"
  tier            = "Standard"
  allowed_pattern = "^[A-Za-z0-9_]{1,64}$"
  value           = aws_db_instance.demo.username

  tags = {
    Name = "${local.name_prefix}-runtime-db-username"
  }
}

resource "aws_ssm_parameter" "runtime_cors_allowed_origins" {
  name            = "${local.runtime_parameter_prefix}/cors-allowed-origins"
  description     = "Comma separated Phase 5C CORS allowlist for the Demo API runtime. Not a secret."
  type            = "String"
  tier            = "Standard"
  allowed_pattern = "^https?://[A-Za-z0-9.:-]+(,https?://[A-Za-z0-9.:-]+)*$"
  value           = join(",", local.runtime_cors_allowed_origins)

  tags = {
    Name = "${local.name_prefix}-runtime-cors-allowed-origins"
  }
}
