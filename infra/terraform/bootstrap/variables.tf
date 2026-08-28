variable "owner" {
  description = "Repository owner or team responsible for the Terraform state bucket. Do not use personal data or secrets."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be blank."
  }
}
