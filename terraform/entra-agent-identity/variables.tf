variable "tenant_id" {
  type = string
}

variable "client_id" {
  type        = string
  description = "Service principal running Terraform. Needs Application.ReadWrite.OwnedBy and AppRoleAssignment.ReadWrite.All."
}

variable "client_secret" {
  type      = string
  sensitive = true
}

variable "agent_name" {
  type        = string
  default     = "example-trial-intake-agent"
  description = "Used as the display name of the agent's Entra identity."
}

variable "owner_object_ids" {
  type        = list(string)
  default     = []
  description = "Entra object ids of the humans accountable for this agent, added as owners alongside the Terraform SPN (which always stays an owner)."
}

variable "graph_application_permissions" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Microsoft Graph application permissions to grant the agent identity, by value -
    for example ["Sites.Selected", "User.Read.All"].

    Keep this list short and reviewable. It is the single most useful thing to put in
    front of an approver: it is the blast radius of the agent, written down.
  EOT
}

variable "sign_in_audience" {
  type        = string
  default     = "AzureADMyOrg"
  description = "Single-tenant by default. Agents should very rarely be multitenant."
}

variable "create_client_secret" {
  type        = bool
  default     = false
  description = <<-EOT
    Create a client secret for the agent identity.

    Off by default. Prefer federated credentials or a managed identity - a long-lived
    secret in Terraform state is exactly the credential an access review cannot revoke.
  EOT
}

variable "secret_end_date_relative" {
  type        = string
  default     = "2160h" # 90 days
  description = "Lifetime of the client secret when create_client_secret is true."
}
