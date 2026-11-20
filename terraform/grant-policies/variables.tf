variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "iam_path" {
  type        = string
  default     = "/balkanid-agents/"
  description = "IAM path for the grant policies. Bedrock developer agents use /balkanid-agents/; the Kiro reference uses /balkanid-kiro-agents/. Must match the provisioner policy and the agent permissions boundary path."

  validation {
    condition     = can(regex("^/([A-Za-z0-9+=,.@_-]+/)+$", var.iam_path))
    error_message = "iam_path must start and end with / (for example /balkanid-agents/)."
  }
}

variable "secret_arns" {
  type        = list(string)
  description = "Secrets Manager secret ARNs an approved agent may read during a BalkanID secrets-read grant. List them explicitly; a wildcard defeats the point of the grant."

  validation {
    condition     = length(var.secret_arns) > 0 && !contains(var.secret_arns, "*")
    error_message = "secret_arns must list at least one secret ARN and must not be \"*\"."
  }
}

variable "ssm_parameter_arns" {
  type        = list(string)
  default     = []
  description = "SSM parameter ARNs (or path ARNs ending in /*) readable during a secrets-read grant. Empty omits SSM access."
}

variable "customer_data_bucket_arns" {
  type        = list(string)
  default     = []
  description = "S3 buckets holding customer data, readable only during a BalkanID customer-data grant."
}
