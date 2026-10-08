variable "aws_region" {
  description = "Region of the Terraform state bucket."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Globally unique name of the state bucket. Null uses te-tengo-terraform-state-<account-id>."
  type        = string
  default     = null
}

variable "noncurrent_version_retention_days" {
  description = "Days old state versions are kept (each apply writes a new version)."
  type        = number
  default     = 90
}
