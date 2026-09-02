variable "owner" {
  description = "Repository owner or team responsible for the Demo resources. Do not use personal data or secrets."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be blank."
  }
}

variable "alert_email" {
  description = "Email endpoint for Demo Scheduler and Budget alerts. The address is stored in Terraform state and requires SNS confirmation."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", var.alert_email))
    error_message = "alert_email must be a non-blank email address."
  }
}

variable "availability_zones" {
  description = "Tokyo Availability Zones selected for the app and two distinct private DB subnets. Confirm availability in the target AWS account before apply."
  type = object({
    public_app   = string
    private_db_a = string
    private_db_b = string
  })

  default = {
    public_app   = "ap-northeast-1a"
    private_db_a = "ap-northeast-1a"
    private_db_b = "ap-northeast-1c"
  }

  validation {
    condition = alltrue([
      for availability_zone in values(var.availability_zones) : can(regex("^ap-northeast-1[a-z]$", availability_zone))
    ])
    error_message = "All availability zones must belong to ap-northeast-1."
  }

  validation {
    condition     = var.availability_zones.private_db_a != var.availability_zones.private_db_b
    error_message = "private_db_a and private_db_b must use different Availability Zones."
  }
}

variable "db_master_password" {
  description = "Ephemeral MariaDB master password supplied only for an approved plan/apply operation. Never commit or output this value."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition = (
      can(regex("^[!-~]{16,41}$", var.db_master_password)) &&
      !can(regex("[/@\"']", var.db_master_password))
    )
    error_message = "db_master_password must be 16-41 printable ASCII characters without whitespace, slash, at sign, double quotes, or single quotes."
  }
}

variable "db_master_password_version" {
  description = "Non-secret rotation version shared by the RDS and SSM write-only password arguments. Increment only with a new password."
  type        = number
  default     = 1

  validation {
    condition     = var.db_master_password_version >= 1 && floor(var.db_master_password_version) == var.db_master_password_version
    error_message = "db_master_password_version must be a positive integer."
  }
}

variable "auth_jwt_secret" {
  description = "Ephemeral JWT signing secret supplied only for an approved apply operation. Use at least 32 high-entropy characters and never commit or output this value."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = length(var.auth_jwt_secret) >= 32
    error_message = "auth_jwt_secret must contain at least 32 characters."
  }
}

variable "auth_jwt_secret_version" {
  description = "Non-secret rotation version for the JWT signing secret write-only argument. Increment only with a new secret."
  type        = number
  default     = 1

  validation {
    condition     = var.auth_jwt_secret_version >= 1 && floor(var.auth_jwt_secret_version) == var.auth_jwt_secret_version
    error_message = "auth_jwt_secret_version must be a positive integer."
  }
}

variable "route53_public_hosted_zone_id" {
  description = "ID of the existing public Route 53 hosted zone for yoonec.dev. Supply this at runtime and never hardcode an account-specific value."
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]+$", var.route53_public_hosted_zone_id))
    error_message = "route53_public_hosted_zone_id must be a non-blank Route 53 hosted zone ID beginning with Z."
  }
}

variable "origin_verify_token" {
  description = "High-entropy defense-in-depth token for the future CloudFront X-Origin-Verify header. Supply 32-128 URL-safe characters at runtime."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{32,128}$", var.origin_verify_token))
    error_message = "origin_verify_token must contain 32-128 URL-safe characters using only letters, digits, underscore, and hyphen."
  }
}

variable "origin_verify_token_version" {
  description = "Non-secret rotation version for the origin verification token write-only argument. Increment only with a new token."
  type        = number
  default     = 1

  validation {
    condition     = var.origin_verify_token_version >= 1 && floor(var.origin_verify_token_version) == var.origin_verify_token_version
    error_message = "origin_verify_token_version must be a positive integer."
  }
}
