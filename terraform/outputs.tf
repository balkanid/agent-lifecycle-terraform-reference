output "gate_completed" {
  value = null_resource.balkanid_gate.id
}

output "bedrock_agent_id" {
  value = try(aws_bedrockagent_agent.this[0].agent_id, null)
}

output "bedrock_agent_role_arn" {
  value = try(aws_iam_role.bedrock_agent[0].arn, null)
}
