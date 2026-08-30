variable "run_balkanid_gate" {
  type        = bool
  default     = true
  description = "When false, skip gate local-exec (CD runs gate.py in the workflow first)."
}

variable "agent_name" {
  type    = string
  default = "demo-support-agent"
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

variable "agent_owner_email" {
  type        = string
  description = "Email of the employee who will own the agent (createRequest employeeEmail)."
}

variable "integration_id" {
  type        = string
  default     = ""
  description = "Optional integration id for createRequest AGENT_ACCESS payload."
}

variable "agent_type" {
  type        = string
  default     = "terraform"
  description = "Agent classification passed to createRequest AGENT_ACCESS payload."
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
