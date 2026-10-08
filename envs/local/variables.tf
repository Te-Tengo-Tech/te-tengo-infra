variable "floci_endpoint" {
  description = "URL of the Floci emulator. `make local-up` publishes it on host port 24566 so it does not clash with the API's own Floci on 4566."
  type        = string
  default     = "http://localhost:24566"

  validation {
    condition     = can(regex("^http://(localhost|127\\.0\\.0\\.1|floci)(:[0-9]+)?$", var.floci_endpoint))
    error_message = "floci_endpoint must be a local emulator URL (http://localhost:<port>), never a real AWS endpoint."
  }
}

variable "aws_region" {
  description = "Region the emulator reports."
  type        = string
  default     = "us-east-1"
}

variable "enable_ses" {
  description = "Create the SES identities in the emulator."
  type        = bool
  default     = true
}

variable "enable_sns" {
  description = "Create the SNS platform application in the emulator (off in the MVP; on here to exercise the code path)."
  type        = bool
  default     = true
}

variable "enable_github_deploy" {
  description = "Create the GitHub OIDC provider and deploy role in the emulator."
  type        = bool
  default     = true
}

variable "enable_route53" {
  description = "Create a tetengo.test hosted zone in the emulator and exercise the Route53 records."
  type        = bool
  default     = true
}
