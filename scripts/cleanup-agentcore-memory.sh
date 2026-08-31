#!/usr/bin/env bash
# Delete orphan AgentCore Memory resources for the configured agent name.
# Harness destroy does not always remove managed memory; failed creates can leave orphans too.
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
  echo "aws CLI is required (bedrock-agentcore-control list-memories / delete-memory)" >&2
  echo "Install awscli or set AWS_CLI to the binary path in .env" >&2
  exit 1
fi

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  echo "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are required (export or set in .env)" >&2
  exit 1
fi

region="${AWS_REGION:-us-east-1}"
agent_name="${AGENT_NAME:-demo-support-agent}"
harness_name="${agent_name//-/_}"
wait_seconds="${AGENTCORE_MEMORY_DELETE_WAIT_SECONDS:-120}"

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$region"

list_matching_memory_ids() {
  aws_cli bedrock-agentcore-control list-memories \
    --region "$region" \
    --no-cli-pager \
    --query "memories[?name=='${harness_name}' || starts_with(id, '${harness_name}') || starts_with(id, '${harness_name}-')].id" \
    --output text 2>/dev/null || true
}

wait_for_memory_gone() {
  local memory_id="$1"
  local elapsed=0
  while (( elapsed < wait_seconds )); do
    if ! aws_cli bedrock-agentcore-control get-memory \
      --memory-id "$memory_id" \
      --region "$region" \
      --no-cli-pager >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "error: memory ${memory_id} still present after ${wait_seconds}s — name may stay reserved until delete completes" >&2
  return 1
}

memory_ids="$(list_matching_memory_ids)"
memory_ids="${memory_ids//$'\t'/ }"
memory_ids="${memory_ids//  / }"
memory_ids="${memory_ids#None}"
memory_ids="${memory_ids%None}"
memory_ids="$(echo "$memory_ids" | xargs 2>/dev/null || true)"

if [[ -z "$memory_ids" ]]; then
  echo "No AgentCore memories matched name/id '${harness_name}' in ${region}."
  exit 0
fi

echo "Deleting AgentCore memories matching '${harness_name}': ${memory_ids}"
for memory_id in $memory_ids; do
  echo "  -> delete-memory ${memory_id}"
  delete_rc=0
  delete_err="$(aws_cli bedrock-agentcore-control delete-memory \
    --memory-id "$memory_id" \
    --region "$region" \
    --no-cli-pager 2>&1)" || delete_rc=$?
  if [[ "$delete_rc" -eq 0 ]]; then
    wait_for_memory_gone "$memory_id"
    continue
  fi
  if echo "$delete_err" | grep -qiE 'managed and cannot be deleted|ValidationException'; then
    echo "warning: memory ${memory_id} is managed by AgentCore and cannot be deleted directly — skipping (delete harness first)" >&2
    continue
  fi
  echo "error: failed to delete memory ${memory_id}: ${delete_err}" >&2
  exit 1
done

echo "AgentCore memory cleanup complete."
