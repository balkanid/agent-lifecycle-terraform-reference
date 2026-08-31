#!/usr/bin/env bash
# Reconcile AWS with Terraform state before AgentCore apply.
# Clears orphans from partial failed applies: CREATE_FAILED harness, stray IAM role, reserved memory names.
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
role_path="/balkanid-agent-lifecycle/"
harness_in_state=false

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

iam_role_policy_resource() {
  local role_resource="$1"
  case "$role_resource" in
    'aws_iam_role.agentcore[0]') echo 'aws_iam_role_policy.agentcore_invoke[0]' ;;
    'aws_iam_role.bedrock_classic[0]') echo 'aws_iam_role_policy.bedrock_classic_invoke[0]' ;;
    *) echo "" ;;
  esac
}

remove_iam_from_terraform_state() {
  local role_resource="$1"
  local policy_resource
  policy_resource="$(iam_role_policy_resource "$role_resource")"
  if [[ -n "$policy_resource" ]] && state_has "$policy_resource"; then
    echo "  -> terraform state rm ${policy_resource}"
    (cd "$tf_dir" && terraform state rm "$policy_resource")
  fi
  if state_has "$role_resource"; then
    echo "  -> terraform state rm ${role_resource}"
    (cd "$tf_dir" && terraform state rm "$role_resource")
  fi
}

delete_iam_role_in_aws() {
  local policy_names attached_arns
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

  aws_cli iam delete-role --role-name "$role_name" --no-cli-pager
}

reconcile_iam_role() {
  local role_resource="$1"
  local get_err="" get_rc=0 actual_path=""

  if aws_cli iam get-role --role-name "$role_name" --no-cli-pager >/dev/null 2>&1; then
    actual_path="$(aws_cli iam get-role --role-name "$role_name" --query 'Role.Path' --output text --no-cli-pager)"
    if [[ "$actual_path" != "$role_path" ]]; then
      echo "IAM role ${role_name} exists at path ${actual_path} (expected ${role_path})."
      if state_has "$role_resource"; then
        echo "Removing mismatched role from Terraform state so apply can recreate under ${role_path}."
        remove_iam_from_terraform_state "$role_resource"
      fi
      return 0
    fi
    if state_has "$role_resource"; then
      echo "IAM role ${role_name} exists in AWS and Terraform state — OK."
    else
      echo "Deleting orphan IAM role ${role_name} (exists in AWS, not in Terraform state)."
      delete_iam_role_in_aws
      echo "Orphan IAM role ${role_name} deleted."
    fi
    return 0
  fi

  get_err="$(aws_cli iam get-role --role-name "$role_name" --no-cli-pager 2>&1)" || get_rc=$?
  if echo "$get_err" | grep -q 'NoSuchEntity'; then
    if state_has "$role_resource"; then
      echo "IAM role ${role_name} is in Terraform state but absent in AWS — removing from state."
      remove_iam_from_terraform_state "$role_resource"
    else
      echo "No IAM role named ${role_name}."
    fi
    return 0
  fi

  echo "error: cannot read IAM role ${role_name} (exit ${get_rc}): ${get_err}" >&2
  echo "error: ensure your Terraform IAM user has the full aws/bedrock-agent-lifecycle-iam-policy.json attached in AWS (replace entire policy)." >&2
  return 1
}

delete_harness_if_orphan_or_failed() {
  local harness_resource="aws_bedrockagentcore_harness.this[0]"
  local in_state=false
  if state_has "$harness_resource"; then
    in_state=true
  fi

  local raw
  raw="$(aws_cli bedrock-agentcore-control list-harnesses \
    --region "$region" \
    --no-cli-pager \
    --output json 2>/dev/null || echo '{"harnesses":[]}')"

  local matches
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

    if [[ "$in_state" == true && "$status" == "READY" ]]; then
      echo "Harness ${harness_id} (${harness_name}) is READY and in Terraform state — leaving in place."
      continue
    fi

    echo "Deleting harness ${harness_id} (${harness_name}, status=${status}, in_state=${in_state})."
    if ! aws_cli bedrock-agentcore-control delete-harness \
      --harness-id "$harness_id" \
      --region "$region" \
      --no-cli-pager; then
      echo "warning: delete-harness ${harness_id} failed — continuing" >&2
    fi
  done <<< "$matches"

  if [[ "$in_state" == true && -z "$matches" ]]; then
    echo "Harness ${harness_name} is in Terraform state but absent in AWS — removing from state."
    (cd "$tf_dir" && terraform state rm "$harness_resource" 2>/dev/null || true)
    in_state=false
  fi

  harness_in_state=false
  if state_has "$harness_resource"; then
    harness_in_state=true
  fi
}

reset_iam_for_fresh_apply() {
  local role_resource="$1"
  echo "Harness not in Terraform state — resetting IAM role for a clean apply (typical after destroy or partial teardown)."
  remove_iam_from_terraform_state "$role_resource"
  # Belt-and-suspenders: remove any IAM role/policy still in state (e.g. if case patterns missed [0] resources).
  while IFS= read -r resource; do
    [[ -z "$resource" ]] && continue
    case "$resource" in
      aws_iam_role.*|aws_iam_role_policy.*)
        echo "  -> terraform state rm ${resource}"
        (cd "$tf_dir" && terraform state rm "$resource")
        ;;
    esac
  done <<< "$(terraform_state_list)"
  if aws_cli iam list-role-policies --role-name "$role_name" --no-cli-pager >/dev/null 2>&1; then
    echo "Deleting IAM role ${role_name} from AWS so apply can recreate it."
    delete_iam_role_in_aws
    echo "IAM role ${role_name} deleted."
  else
    echo "IAM role ${role_name} not present in AWS (or not listable) — apply will create it."
  fi
}

echo "==> AgentCore pre-apply reconciliation (agent=${agent_name}, region=${region})"

delete_harness_if_orphan_or_failed

backend_lc="$(printf '%s' "${AGENT_BACKEND:-agentcore}" | tr '[:upper:]' '[:lower:]')"
if [[ "$backend_lc" == "agentcore" ]]; then
  role_resource="aws_iam_role.agentcore[0]"
else
  role_resource="aws_iam_role.bedrock_classic[0]"
fi

if [[ "$harness_in_state" == true ]]; then
  reconcile_iam_role "$role_resource"
else
  reset_iam_for_fresh_apply "$role_resource"
fi

echo "==> AgentCore memory cleanup"
bash "$root/scripts/cleanup-agentcore-memory.sh"

echo "AgentCore pre-apply reconciliation complete."
