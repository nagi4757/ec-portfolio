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
