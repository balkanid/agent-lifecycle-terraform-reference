#!/usr/bin/env bash
# After terraform destroy, remove AgentCore harnesses that still exist in AWS.
# Terraform can drop the harness from state during refresh without calling delete-harness
# (e.g. partial prior destroys, state/cache drift). Always reconcile by agent name on teardown.
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

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$region"

echo "==> AgentCore harness teardown (agent=${agent_name}, region=${region})"

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
else
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
    echo "error: delete-harness ${harness_id} failed: ${delete_err}" >&2
    exit 1
  done <<< "$matches"
fi

echo "==> AgentCore memory cleanup"
bash "$root/scripts/cleanup-agentcore-memory.sh"

echo "AgentCore destroy cleanup complete."
