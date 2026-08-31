output "agent_backend" {
  value = var.agent_backend
}

output "bedrock_agent_id" {
  value       = local.use_classic ? aws_bedrockagent_agent.this[0].agent_id : null
  description = "Bedrock Agents Classic agent id (classic backend only)."
}

output "agentcore_harness_id" {
  value       = local.use_agentcore ? aws_bedrockagentcore_harness.this[0].harness_id : null
  description = "AgentCore harness id (agentcore backend only)."
}

output "agentcore_harness_name" {
  value       = local.use_agentcore ? aws_bedrockagentcore_harness.this[0].harness_name : null
  description = "AgentCore harness name (agentcore backend only)."
}

output "execution_role_arn" {
  value       = aws_iam_role.execution[0].arn
  description = "IAM role the agent/harness runs as."
}
