variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "aws_credentials_file" {
  type        = string
  description = "Isolated credentials file path (written by scripts/terraform-local.sh); never use ~/.aws/config."
}

variable "aws_account_id" {
  type        = string
  description = "12-digit AWS account id for Bedrock IAM trust policy."
}

variable "agent_name" {
  type    = string
  default = "demo-support-agent"
}

variable "agent_backend" {
  type        = string
  description = "Agent provisioning backend: agentcore (default, new accounts) or classic (Bedrock Agents Classic, allowlisted accounts only)."
  default     = "agentcore"

  validation {
    condition     = contains(["classic", "agentcore"], var.agent_backend)
    error_message = "agent_backend must be \"classic\" or \"agentcore\"."
  }
}

variable "foundation_model" {
  type    = string
  default = "amazon.nova-micro-v1:0"
}

variable "agent_instruction" {
  type    = string
  default = "You are a demo assistant. Do not perform real actions against production systems."
}

variable "execution_role_arn" {
  type        = string
  description = "When set (EN-8896 JIT mode), skip creating aws_iam_role and attach the harness to this BalkanID-provisioned role ARN."
  default     = ""
}
