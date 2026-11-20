output "application_id" {
  description = "Entra app id of the agent identity. Pass to the Copilot Studio stack as agent_application_id."
  value       = azuread_application.agent.client_id
}

output "service_principal_object_id" {
  description = "Object id of the agent's service principal, as it appears in BalkanID."
  value       = azuread_service_principal.agent.object_id
}

output "granted_graph_permissions" {
  description = "Graph application permissions admin-consented to the agent."
  value       = keys(local.graph_role_ids)
}

output "client_secret" {
  description = "Client secret, only when create_client_secret is true. Prefer federated credentials."
  value       = var.create_client_secret ? azuread_application_password.agent[0].value : ""
  sensitive   = true
}
