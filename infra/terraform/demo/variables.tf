variable "owner" {
  description = "Repository owner or team responsible for the Demo resources. Do not use personal data or secrets."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be blank."
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
