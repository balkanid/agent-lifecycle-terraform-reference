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

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$region"

# shellcheck source=scripts/reconcile-terraform-iam-state.sh
source "$root/scripts/reconcile-terraform-iam-state.sh"

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

harness_in_state=false
harness_ready_in_aws=false

find_role_globally() {
  # Prints "path<TAB>arn" for the first matching role name, or empty if not listable/absent.
  aws_cli iam list-roles \
    --query "Roles[?RoleName=='${role_name}'] | [0].[Path,Arn]" \
    --output text \
    --no-cli-pager 2>/dev/null || true
}

# Echo one of: lifecycle | outside | absent | unverified
iam_role_status() {
  local global path arn get_err="" get_rc=0

  global="$(find_role_globally)"
  global="${global//$'\n'/}"
  if [[ -n "$global" && "$global" != "None" && "$global" != "None None" ]]; then
    path="${global%%$'\t'*}"
    arn="${global#*$'\t'}"
    if [[ "$path" == "$role_path" ]]; then
      echo "lifecycle"
    else
      printf 'outside|%s|%s\n' "$path" "$arn"
    fi
    return 0
  fi

  if aws_cli iam get-role --role-name "$role_name" --no-cli-pager >/dev/null 2>&1; then
    path="$(aws_cli iam get-role --role-name "$role_name" --query 'Role.Path' --output text --no-cli-pager)"
    arn="$(aws_cli iam get-role --role-name "$role_name" --query 'Role.Arn' --output text --no-cli-pager)"
    if [[ "$path" == "$role_path" ]]; then
      echo "lifecycle"
    else
      printf 'outside|%s|%s\n' "$path" "$arn"
    fi
    return 0
  fi

  get_err="$(aws_cli iam get-role --role-name "$role_name" --no-cli-pager 2>&1)" || get_rc=$?
  if echo "$get_err" | grep -q 'NoSuchEntity'; then
    echo "absent"
    return 0
  fi
  if echo "$get_err" | grep -qE 'AccessDenied|not authorized'; then
    echo "unverified"
    return 0
  fi

  echo "error: cannot read IAM role ${role_name} (exit ${get_rc}): ${get_err}" >&2
  return 1
}

report_role_outside_lifecycle_path() {
  local detail="${1:-}"
  echo "error: IAM role ${role_name} exists outside ${role_path}." >&2
  if [[ -n "$detail" ]]; then
    echo "error: Found ${detail}" >&2
  fi
  echo "error: Terraform can only manage roles under role/balkanid-agent-lifecycle/*." >&2
  echo "error: Delete the conflicting role (needs IAM admin) or use a different AGENT_NAME, then re-run CD." >&2
}

report_role_unverified() {
  echo "warning: cannot verify IAM role ${role_name} (iam:GetRole denied; role not visible via iam:ListRoles)." >&2
  echo "warning: This can happen with SCPs, an out-of-date bedrock-agent-lifecycle-iam-policy.json, or a hidden same-named role." >&2
  echo "warning: Continuing because the AgentCore harness is READY — Terraform apply will create or refresh the lifecycle-path role." >&2
  echo "warning: If apply fails with EntityAlreadyExists, ask an IAM admin to run: aws iam get-role --role-name ${role_name}" >&2
}

remove_iam_from_terraform_state() {
  purge_all_iam_from_state
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

reconcile_iam_for_apply() {
  local status
  status="$(iam_role_status)" || return 1

  case "$status" in
    lifecycle)
      echo "IAM role ${role_name} verified under ${role_path}."
      ;;
    absent)
      echo "No IAM role ${role_name} in AWS — apply will create under ${role_path}."
      ;;
    unverified)
      report_role_unverified
      ;;
  esac

  if [[ "$status" == outside\|* ]]; then
    if [[ "$harness_ready_in_aws" == true ]]; then
      echo "warning: ${role_name} exists outside ${role_path} — will recreate under lifecycle path on apply." >&2
    else
      report_role_outside_lifecycle_path "${status#outside|}"
      echo "error: Delete the conflicting role or use a different AGENT_NAME." >&2
      return 1
    fi
  fi

  reconcile_terraform_iam_state "$status"
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
      harness_ready_in_aws=true
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
  echo "Harness not in Terraform state — resetting IAM role for a clean apply (typical after destroy or partial teardown)."
  purge_all_iam_from_state
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

if [[ "$harness_in_state" == true ]]; then
  reconcile_iam_for_apply
else
  reset_iam_for_fresh_apply
fi

echo "==> AgentCore memory cleanup"
if [[ "$harness_ready_in_aws" == true ]]; then
  echo "Skipping memory cleanup — harness is READY (memory is managed by the harness)."
else
  bash "$root/scripts/cleanup-agentcore-memory.sh"
fi

echo "AgentCore pre-apply reconciliation complete."
