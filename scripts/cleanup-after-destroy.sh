#!/usr/bin/env bash
# Delete lingering AWS resources for AGENT_NAME after terraform destroy (or failed partial teardown).
# Sweeps AgentCore harness + memory, Classic Bedrock agent, and lifecycle-path IAM role.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -f "$root/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$root/.env"
  set +a
fi

unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE AWS_SDK_LOAD_CONFIG

aws_cli() {
  if [[ -n "${AWS_CLI:-}" ]]; then
    "$AWS_CLI" "$@"
    return
  fi
  command aws "$@"
}

if ! command -v aws >/dev/null 2>&1 && [[ -z "${AWS_CLI:-}" ]]; then
  echo "aws CLI is required" >&2
  exit 1
fi

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  echo "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are required" >&2
  exit 1
fi

region="${AWS_REGION:-us-east-1}"
agent_name="${AGENT_NAME:-demo-support-agent}"
harness_name="${agent_name//-/_}"
role_name="${agent_name}"
role_path="/balkanid-agent-lifecycle/"

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$region"

warn() {
  echo "warning: $*" >&2
}

lifecycle_path_role_exists() {
  local count
  count="$(aws_cli iam list-roles \
    --path-prefix "$role_path" \
    --query "length(Roles[?RoleName=='${role_name}'])" \
    --output text \
    --no-cli-pager 2>/dev/null || echo "0")"
  [[ "$count" == "1" ]]
}

delete_iam_role_in_aws() {
  local policy_names attached_arns profiles
  policy_names="$(aws_cli iam list-role-policies --role-name "$role_name" --query 'PolicyNames[]' --output text --no-cli-pager 2>/dev/null || true)"
  for policy_name in $policy_names; do
    [[ -z "$policy_name" || "$policy_name" == "None" ]] && continue
    echo "  -> delete inline policy ${policy_name}"
    aws_cli iam delete-role-policy --role-name "$role_name" --policy-name "$policy_name" --no-cli-pager
  done

  attached_arns="$(aws_cli iam list-attached-role-policies --role-name "$role_name" --query 'AttachedPolicies[].PolicyArn' --output text --no-cli-pager 2>/dev/null || true)"
  for policy_arn in $attached_arns; do
    [[ -z "$policy_arn" || "$policy_arn" == "None" ]] && continue
    echo "  -> detach managed policy ${policy_arn}"
    aws_cli iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn" --no-cli-pager
  done

  profiles="$(aws_cli iam list-instance-profiles-for-role --role-name "$role_name" --query 'InstanceProfiles[].InstanceProfileName' --output text --no-cli-pager 2>/dev/null || true)"
  for profile_name in $profiles; do
    [[ -z "$profile_name" || "$profile_name" == "None" ]] && continue
    echo "  -> remove role from instance profile ${profile_name}"
    aws_cli iam remove-role-from-instance-profile --instance-profile-name "$profile_name" --role-name "$role_name" --no-cli-pager
  done

  aws_cli iam delete-role --role-name "$role_name" --no-cli-pager
}

delete_harness_endpoints() {
  local harness_id="$1"
  local raw endpoint_ids
  raw="$(aws_cli bedrock-agentcore-control list-harness-endpoints \
    --harness-id "$harness_id" \
    --region "$region" \
    --no-cli-pager \
    --output json 2>/dev/null || echo '{"harnessEndpoints":[]}')"

  endpoint_ids="$(printf '%s' "$raw" | python3 -c "
import json, sys
for ep in json.load(sys.stdin).get('harnessEndpoints') or []:
    eid = ep.get('harnessEndpointId') or ep.get('id')
    if eid:
        print(eid)
")"

  while read -r endpoint_id; do
    [[ -z "$endpoint_id" ]] && continue
    echo "  -> delete-harness-endpoint ${endpoint_id}"
    if ! aws_cli bedrock-agentcore-control delete-harness-endpoint \
      --harness-id "$harness_id" \
      --harness-endpoint-id "$endpoint_id" \
      --region "$region" \
      --no-cli-pager; then
      warn "delete-harness-endpoint ${endpoint_id} failed — continuing"
    fi
  done <<< "$endpoint_ids"
}

delete_agentcore_harnesses() {
  local raw matches found=false
  raw="$(aws_cli bedrock-agentcore-control list-harnesses \
    --region "$region" \
    --no-cli-pager \
    --output json 2>/dev/null || echo '{"harnesses":[]}')"

  matches="$(printf '%s' "$raw" | python3 -c "
import json, sys
name = sys.argv[1]
for h in json.load(sys.stdin).get('harnesses') or []:
    if h.get('harnessName') == name:
        print(h.get('harnessId', ''), h.get('status', 'UNKNOWN'))
" "$harness_name")"

  if [[ -z "$matches" ]]; then
    echo "No AgentCore harness named ${harness_name} in ${region}."
    return 0
  fi

  while read -r harness_id status; do
    [[ -z "$harness_id" ]] && continue
    found=true
    echo "Deleting harness ${harness_id} (${harness_name}, status=${status})."
    delete_harness_endpoints "$harness_id"
    if ! aws_cli bedrock-agentcore-control delete-harness \
      --harness-id "$harness_id" \
      --region "$region" \
      --no-cli-pager; then
      warn "delete-harness ${harness_id} failed — continuing"
    fi
  done <<< "$matches"

  if [[ "$found" == false ]]; then
    echo "No AgentCore harness named ${harness_name} in ${region}."
  fi
}

delete_classic_agents() {
  local agent_ids alias_ids agent_id alias_id
  agent_ids="$(aws_cli bedrock-agent list-agents \
    --region "$region" \
    --no-cli-pager \
    --query "agentSummaries[?agentName=='${agent_name}'].agentId" \
    --output text 2>/dev/null || true)"
  agent_ids="${agent_ids//$'\t'/ }"
  agent_ids="${agent_ids#None}"
  agent_ids="${agent_ids%None}"
  agent_ids="$(echo "$agent_ids" | xargs 2>/dev/null || true)"

  if [[ -z "$agent_ids" ]]; then
    echo "No Classic Bedrock agent named ${agent_name} in ${region}."
    return 0
  fi

  for agent_id in $agent_ids; do
    echo "Deleting Classic agent ${agent_id} (${agent_name})."
    alias_ids="$(aws_cli bedrock-agent list-agent-aliases \
      --agent-id "$agent_id" \
      --region "$region" \
      --no-cli-pager \
      --query 'agentAliasSummaries[].agentAliasId' \
      --output text 2>/dev/null || true)"
    for alias_id in $alias_ids; do
      [[ -z "$alias_id" || "$alias_id" == "None" ]] && continue
      echo "  -> delete-agent-alias ${alias_id}"
      if ! aws_cli bedrock-agent delete-agent-alias \
        --agent-id "$agent_id" \
        --agent-alias-id "$alias_id" \
        --region "$region" \
        --no-cli-pager; then
        warn "delete-agent-alias ${alias_id} failed — continuing"
      fi
    done
    if ! aws_cli bedrock-agent delete-agent \
      --agent-id "$agent_id" \
      --region "$region" \
      --skip-resource-in-use-check \
      --no-cli-pager; then
      warn "delete-agent ${agent_id} failed — continuing"
    fi
  done
}

delete_lifecycle_iam_role() {
  if ! lifecycle_path_role_exists; then
    echo "No IAM role ${role_name} under ${role_path}."
    return 0
  fi
  echo "Deleting IAM role ${role_name} under ${role_path}."
  delete_iam_role_in_aws
  echo "IAM role ${role_name} deleted."
}

echo "==> Post-destroy AWS sweep (agent=${agent_name}, region=${region})"

echo "==> AgentCore harnesses"
delete_agentcore_harnesses

echo "==> AgentCore memory"
if ! bash "$root/scripts/cleanup-agentcore-memory.sh"; then
  warn "AgentCore memory cleanup reported errors — continuing sweep"
fi

echo "==> Classic Bedrock agents"
delete_classic_agents

echo "==> IAM execution role"
delete_lifecycle_iam_role

echo "Post-destroy AWS sweep complete."
