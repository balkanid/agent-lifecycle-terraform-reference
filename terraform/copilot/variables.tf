variable "run_agent_gate" {
  type        = bool
  default     = true
  description = "When false, skip the gate local-exec (CD runs the gate script in the workflow instead)."
}

variable "agent_name" {
  type        = string
  default     = "example-trial-intake-agent"
  description = "Agent name used in the access request and in the provisioned resource."
}

variable "agent_type" {
  type        = string
  default     = "copilot-studio"
  description = "Agent classification passed to createRequest AGENT_ACCESS."
}

variable "agent_purpose" {
  type        = string
  default     = "Copilot agent provisioned with BalkanID approval"
  description = "Business justification shown to the approver."
}

variable "agent_schema_name" {
  type        = string
  default     = ""
  description = "Copilot Studio schema name (stable across environments, unlike the bot GUID)."
}

variable "solution_unique_name" {
  type        = string
  default     = ""
  description = "Power Platform solution carrying the agent, shown on the access request."
}

variable "power_platform_environment_id" {
  type        = string
  default     = ""
  description = "Target Power Platform environment id, shown on the access request."
}

variable "intended_agent_identity_id" {
  type        = string
  default     = ""
  description = "Entra app id / agent identity the agent will run as, when known before creation."
}

# --- BalkanID -----------------------------------------------------------------

variable "balkanid_public_api_url" {
  type        = string
  default     = "https://your-tenant.example.com/api/public"
  description = "BalkanID Public API base URL for your tenant."
}

variable "api_key_id" {
  type        = string
  sensitive   = true
  default     = ""
  description = "BalkanID employee API key id."
}

variable "api_key_secret" {
  type        = string
  sensitive   = true
  default     = ""
  description = "BalkanID employee API key secret."
}

variable "agent_owner_email" {
  type        = string
  sensitive   = true
  description = "Email of the employee who will own the agent (createRequest employeeEmail)."
}

variable "integration_id" {
  type        = string
  sensitive   = true
  default     = ""
  description = "BalkanID integration id (Entra / M365 / Power Platform) associated with the agent."
}

# --- Polling ------------------------------------------------------------------

variable "poll_seconds" {
  type        = number
  default     = 5
  description = "Seconds between approval status polls."
}

variable "poll_timeout_seconds" {
  type        = number
  default     = 900
  description = "Fail the apply if approval has not landed within this window."
}
