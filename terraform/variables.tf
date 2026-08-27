variable "enable_bedrock" {
  type        = bool
  default     = false
  description = "When false, only the BalkanID gate runs. Set true to also create a Bedrock agent."
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "agent_name" {
  type    = string
  default = "demo-support-agent"
}

variable "foundation_model" {
  type        = string
  default     = "amazon.nova-micro-v1:0"
  description = "Must be enabled in Bedrock model access for this account/region."
}

variable "agent_instruction" {
  type    = string
  default = "You are a demo assistant. Do not perform real actions against production systems."
}

variable "balkanid_public_api_url" {
  type    = string
  default = "https://your-tenant.balkanid.app/api/public"
}

variable "api_key_id" {
  type      = string
  sensitive = true
}

variable "api_key_secret" {
  type      = string
  sensitive = true
}

variable "employee_email" {
  type = string
}

variable "integration_id" {
  type = string
}

variable "agent_owner_email" {
  type    = string
  default = ""
}

variable "agent_purpose" {
  type    = string
  default = "Demo agent created via agent-lifecycle PoV"
}

variable "intended_iam_role_arn" {
  type    = string
  default = ""
}

variable "poll_seconds" {
  type    = number
  default = 5
}

variable "poll_timeout_seconds" {
  type    = number
  default = 900
}
