#!/usr/bin/env bash
# Before terraform destroy: delete harness in AWS and drop stale resources from TF state.
# Avoids destroy failing on GetRole/GetHarness refresh when AWS was partially torn down.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tf_dir="${root}/terraform/bedrock"

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

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$region"

terraform_state_list() {
  if [[ ! -d "$tf_dir/.terraform" ]]; then
    return 0
  fi
  (cd "$tf_dir" && terraform state list 2>/dev/null) || true
}

state_has() {
  local resource="$1"
  terraform_state_list | grep -Fxq "$resource"
}

state_rm() {
  local resource="$1"
  if state_has "$resource"; then
    echo "  -> terraform state rm ${resource}"
    (cd "$tf_dir" && terraform state rm "$resource")
  fi
}

remove_iam_from_terraform_state() {
  local role_resource="$1"
  local policy_resource=""
  case "$role_resource" in
    'aws_iam_role.agentcore[0]') policy_resource='aws_iam_role_policy.agentcore_invoke[0]' ;;
    'aws_iam_role.bedrock_classic[0]') policy_resource='aws_iam_role_policy.bedrock_classic_invoke[0]' ;;
  esac
  [[ -n "$policy_resource" ]] && state_rm "$policy_resource"
  state_rm "$role_resource"
}

delete_harnesses_in_aws() {
  local raw matches
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
    echo "Deleting harness ${harness_id} (${harness_name}, status=${status})."
    if ! aws_cli bedrock-agentcore-control delete-harness \
      --harness-id "$harness_id" \
      --region "$region" \
      --no-cli-pager; then
      echo "warning: delete-harness ${harness_id} failed — continuing" >&2
    fi
  done <<< "$matches"
}

reconcile_iam_for_destroy() {
  local role_resource="$1"
  if ! state_has "$role_resource"; then
    return 0
  fi

  if aws_cli iam get-role --role-name "$role_name" --no-cli-pager >/dev/null 2>&1; then
    echo "IAM role ${role_name} exists — Terraform destroy will remove it."
    return 0
  fi

  echo "IAM role ${role_name} absent or not readable — removing from Terraform state."
  remove_iam_from_terraform_state "$role_resource"
}

backend_lc="$(printf '%s' "${AGENT_BACKEND:-agentcore}" | tr '[:upper:]' '[:lower:]')"
if [[ "$backend_lc" == "agentcore" ]]; then
  role_resource="aws_iam_role.agentcore[0]"
  harness_resource="aws_bedrockagentcore_harness.this[0]"
else
  role_resource="aws_iam_role.bedrock_classic[0]"
  harness_resource="aws_bedrockagent_agent.this[0]"
fi

echo "==> AgentCore pre-destroy reconciliation (agent=${agent_name}, region=${region})"

delete_harnesses_in_aws
state_rm "$harness_resource"
reconcile_iam_for_destroy "$role_resource"

echo "AgentCore pre-destroy reconciliation complete."
