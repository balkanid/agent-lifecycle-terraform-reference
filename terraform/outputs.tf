output "gate_completed" {
  value = var.run_balkanid_gate ? null_resource.balkanid_gate[0].id : "skipped"
}

output "bedrock_agent_id" {
  value = try(aws_bedrockagent_agent.this[0].agent_id, null)
}

output "bedrock_agent_role_arn" {
  value = try(aws_iam_role.bedrock_agent[0].arn, null)
}
