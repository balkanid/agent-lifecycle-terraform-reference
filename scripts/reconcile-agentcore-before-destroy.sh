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

state_rm() {
  local resource="$1"
  if state_has "$resource"; then
    echo "  -> terraform state rm ${resource}"
    (cd "$tf_dir" && terraform state rm "$resource")
  fi
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
    if [[ "$status" == "DELETING" ]]; then
      echo "Harness ${harness_id} (${harness_name}) is already DELETING — skipping."
      continue
    fi
    echo "Deleting harness ${harness_id} (${harness_name}, status=${status})."
    delete_err=""
    delete_rc=0
    delete_err="$(aws_cli bedrock-agentcore-control delete-harness \
      --harness-id "$harness_id" \
      --region "$region" \
      --no-cli-pager 2>&1)" || delete_rc=$?
    if [[ "$delete_rc" -eq 0 ]]; then
      continue
    fi
    if echo "$delete_err" | grep -qiE 'DELETING|ConflictException'; then
      echo "warning: harness ${harness_id} already deleting — continuing" >&2
      continue
    fi
    echo "warning: delete-harness ${harness_id} failed — continuing" >&2
  done <<< "$matches"
}

find_role_globally() {
  aws_cli iam list-roles \
    --query "Roles[?RoleName=='${role_name}'] | [0].[Path,Arn]" \
    --output text \
    --no-cli-pager 2>/dev/null || true
}

iam_role_status() {
  local global path arn get_err="" get_rc=0

  global="$(find_role_globally)"
  global="${global//$'\n'/}"
  if [[ -n "$global" && "$global" != "None" && "$global" != "None None" ]]; then
    path="${global%%$'\t'*}"
    if [[ "$path" == "$role_path" ]]; then
      echo "lifecycle"
    else
      printf 'outside|%s|%s\n' "$path" "${global#*$'\t'}"
    fi
    return 0
  fi

  if aws_cli iam get-role --role-name "$role_name" --no-cli-pager >/dev/null 2>&1; then
    path="$(aws_cli iam get-role --role-name "$role_name" --query 'Role.Path' --output text --no-cli-pager)"
    if [[ "$path" == "$role_path" ]]; then
      echo "lifecycle"
    else
      arn="$(aws_cli iam get-role --role-name "$role_name" --query 'Role.Arn' --output text --no-cli-pager)"
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

reconcile_iam_for_destroy() {
  local status
  status="$(iam_role_status)" || return 1
  migrate_legacy_iam_state
  case "$status" in
    lifecycle)
      echo "IAM role ${role_name} exists under ${role_path} — Terraform destroy will remove it."
      ;;
    absent|unverified|outside*)
      echo "IAM role ${role_name} is ${status} — purging IAM from Terraform state before destroy."
      purge_all_iam_from_state
      ;;
  esac
}

backend_lc="$(printf '%s' "${AGENT_BACKEND:-agentcore}" | tr '[:upper:]' '[:lower:]')"
if [[ "$backend_lc" == "agentcore" ]]; then
  harness_resource="aws_bedrockagentcore_harness.this[0]"
else
  harness_resource="aws_bedrockagent_agent.this[0]"
fi

echo "==> AgentCore pre-destroy reconciliation (agent=${agent_name}, region=${region})"

delete_harnesses_in_aws
state_rm "$harness_resource"
reconcile_iam_for_destroy

echo "AgentCore pre-destroy reconciliation complete."
