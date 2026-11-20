output "environment_id" {
  description = "Environment the agent was provisioned into."
  value       = local.environment_id
}

output "solution_id" {
  description = "Dataverse solution id carrying the agent, when a solution was imported."
  value       = var.import_solution && var.solution_zip_path != "" ? powerplatform_managed_solution.agent[0].solution_id : ""
}

output "agent_schema_name" {
  description = "Schema name of the published agent."
  value       = var.agent_schema_name
}

output "managed_environment_applied" {
  description = "Whether Managed Environment guardrails were applied."
  value       = var.enable_managed_environment
}
