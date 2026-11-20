# --- Auth ---------------------------------------------------------------------

variable "tenant_id" {
  type        = string
  description = "Entra tenant id."
}

variable "client_id" {
  type        = string
  description = "Service principal application id, registered with Power Platform."
}

variable "client_secret" {
  type      = string
  sensitive = true
}

# --- Environment --------------------------------------------------------------

variable "create_environment" {
  type        = bool
  default     = false
  description = "Create a dedicated environment for the agent. Set false to target an existing one."
}

variable "environment_id" {
  type        = string
  default     = ""
  description = "Existing Power Platform environment id. Required when create_environment is false."
}

variable "environment_display_name" {
  type    = string
  default = "BalkanID agent lifecycle"
}

variable "environment_type" {
  type        = string
  default     = "Sandbox"
  description = "Sandbox, Production, Trial, or Developer."
}

variable "environment_location" {
  type    = string
  default = "unitedstates"
}

variable "environment_language_code" {
  type        = number
  default     = 1033
  description = "Dataverse language LCID. 1033 is en-US."
}

variable "environment_currency_code" {
  type    = string
  default = "USD"
}

variable "environment_security_group_id" {
  type        = string
  default     = "00000000-0000-0000-0000-000000000000"
  description = "Entra security group scoping environment membership. All-zero GUID means open access."
}

# --- Governance guardrails ----------------------------------------------------

variable "enable_managed_environment" {
  type        = bool
  default     = true
  description = "Apply Managed Environment controls, including Copilot sharing limits."
}

variable "copilot_limit_sharing_mode" {
  type        = string
  default     = "ExcludeSharingToSecurityGroups"
  description = "DisableSharing, ExcludeSharingToSecurityGroups, or NoLimit. Case-sensitive. NoLimit removes the control."

  validation {
    condition     = contains(["DisableSharing", "ExcludeSharingToSecurityGroups", "NoLimit"], var.copilot_limit_sharing_mode)
    error_message = "copilot_limit_sharing_mode must be DisableSharing, ExcludeSharingToSecurityGroups, or NoLimit."
  }
}

variable "copilot_max_limit_user_sharing" {
  type        = number
  default     = 10
  description = "Maximum individual users an agent may be shared with. -1 means unlimited."
}

variable "solution_checker_mode" {
  type        = string
  default     = "Warn"
  description = "None, Warn, or Block. Block fails solution import when the checker finds violations. Case-sensitive."

  validation {
    condition     = contains(["None", "Warn", "Block"], var.solution_checker_mode)
    error_message = "solution_checker_mode must be None, Warn, or Block (case-sensitive)."
  }
}

variable "disable_group_sharing" {
  type        = bool
  default     = true
  description = <<-EOT
    Disable sharing with security groups.

    This is the switch that makes the numeric sharing limits mean anything. When it is
    false the provider requires the limits to be -1, so an agent can be shared with
    anyone and the guardrail is decorative.
  EOT
}

variable "limit_sharing_mode" {
  type        = string
  default     = "ExcludeSharingToSecurityGroups"
  description = "ExcludeSharingToSecurityGroups or NoLimit. Case-sensitive."

  validation {
    condition     = contains(["ExcludeSharingToSecurityGroups", "NoLimit"], var.limit_sharing_mode)
    error_message = "limit_sharing_mode must be ExcludeSharingToSecurityGroups or NoLimit."
  }
}

variable "max_limit_user_sharing" {
  type        = number
  default     = 10
  description = "Maximum individual users a canvas app may be shared with, when disable_group_sharing is true."
}

variable "enable_transcript_recording" {
  type        = bool
  default     = true
  description = "Record Copilot Studio transcripts, so agent activity is reviewable after the fact."
}

# --- Agent solution -----------------------------------------------------------

variable "import_solution" {
  type        = bool
  default     = true
  description = "Import the solution that carries the agent. Set false to run guardrails only."
}

variable "solution_zip_path" {
  type        = string
  default     = ""
  description = "Path to the managed solution .zip produced by `pac copilot pack` or `pac solution pack`."
}

variable "solution_unique_name" {
  type        = string
  default     = "BalkanIDAgentLifecycle"
  description = "Solution unique name, as it appears in Dataverse."
}

variable "solution_version" {
  type        = string
  default     = "1.0.0.0"
  description = "Solution version. Must be >= the version already installed."
}

variable "connection_references" {
  type        = map(string)
  default     = {}
  description = "Logical name of each connection reference in the package -> powerplatform_connection id."
}

variable "environment_variables" {
  type        = map(string)
  default     = {}
  description = "Environment variable schema name -> value, applied after import."
}

# --- Agent identity -----------------------------------------------------------

variable "agent_application_id" {
  type        = string
  default     = ""
  description = "Entra app id of the agent identity, granted environment application admin when set."
}

# --- Publish ------------------------------------------------------------------

variable "publish_agent" {
  type        = bool
  default     = true
  description = "Run `pac copilot publish` after import. An imported agent is not live until published."
}

variable "agent_schema_name" {
  type        = string
  default     = ""
  description = "Copilot Studio schema name of the agent to publish."
}

variable "pac_cli" {
  type        = string
  default     = "pac"
  description = "Path to the Power Platform CLI."
}

# --- Telemetry (preview) ------------------------------------------------------

variable "application_insights_connection_string" {
  type        = string
  sensitive   = true
  default     = ""
  description = <<-EOT
    Optional Application Insights wiring for the agent.

    Left empty by default on purpose: powerplatform_copilot_studio_application_insights
    is preview and does not work with service principal authentication, so setting it
    will break an unattended apply. Use it only from an interactive `az login` session.
  EOT
}

variable "agent_bot_id" {
  type        = string
  default     = ""
  description = "Dataverse bot GUID, required only for the Application Insights resource."
}
