#!/usr/bin/env bash
# Local Terraform wrapper: sources .env, avoids ~/.aws profile breakage, runs gate then Bedrock stack.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
set -a
# shellcheck source=/dev/null
source "$root/.env"
set +a

unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE AWS_SDK_LOAD_CONFIG

resolve_aws_account_id() {
  if [[ -n "${AWS_ACCOUNT_ID:-}" ]]; then
    echo "$AWS_ACCOUNT_ID"
    return
  fi
  if [[ "${INTENDED_IAM_ROLE_ARN:-}" =~ arn:aws:iam::([0-9]{12}): ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  echo ""
}

write_aws_credentials_file() {
  local path="$1"
  umask 077
  cat >"$path" <<EOF
[terraform]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF
}

gate_apply_vars=(
  -var="balkanid_public_api_url=${BALKANID_PUBLIC_API_URL}"
  -var="api_key_id=${API_KEY_ID}"
  -var="api_key_secret=${API_KEY_SECRET}"
  -var="agent_owner_email=${BALKANID_AGENT_OWNER_EMAIL}"
  -var="integration_id=${INTEGRATION_ID:-}"
  -var="agent_name=${AGENT_NAME:-demo-support-agent}"
  -var="agent_type=${AGENT_TYPE:-terraform}"
  -var="agent_purpose=${AGENT_PURPOSE:-Agent provisioned via Terraform with BalkanID approval}"
  -var="intended_iam_role_arn=${INTENDED_IAM_ROLE_ARN:-}"
)

cmd="${1:-}"
shift || true

case "$cmd" in
  apply-lifecycle)
    account_id="$(resolve_aws_account_id)"
    if [[ -z "$account_id" ]]; then
      echo "AWS_ACCOUNT_ID is required in .env" >&2
      exit 1
    fi
    cred_file="$(mktemp)"
    trap 'rm -f "$cred_file"' EXIT
    write_aws_credentials_file "$cred_file"

    echo "==> Service account gate" >&2
    export AWS_ACCOUNT_ID="$account_id"
    python3 "$root/scripts/service_account_gate.py"

    echo "==> Agent access gate" >&2
    python3 "$root/scripts/gate.py"

    backend_lc="$(printf '%s' "${AGENT_BACKEND:-agentcore}" | tr '[:upper:]' '[:lower:]')"
    if [[ "$backend_lc" == "agentcore" ]]; then
      echo "==> AgentCore pre-apply reconciliation" >&2
      "$root/scripts/cleanup-agentcore-before-apply.sh"
    fi

    echo "==> Terraform Bedrock stack (backend=${AGENT_BACKEND:-agentcore})" >&2
    cd "$root/terraform/bedrock"
    terraform init -input=false
    terraform apply -auto-approve \
      -var="aws_credentials_file=${cred_file}" \
      -var="aws_account_id=${account_id}" \
      -var="aws_region=${AWS_REGION:-us-east-1}" \
      -var="agent_name=${AGENT_NAME:-demo-support-agent}" \
      -var="agent_backend=${AGENT_BACKEND:-agentcore}" \
      "$@"

    trigger_lc="$(printf '%s' "${TRIGGER_INTEGRATION_SYNC:-true}" | tr '[:upper:]' '[:lower:]')"
    case "$trigger_lc" in
      0|false|no|off)
        echo "==> TRIGGER_INTEGRATION_SYNC disabled; skipping sync" >&2
        exit 0
        ;;
    esac
    if [[ -z "${INTEGRATION_ID:-}" ]]; then
      echo "==> INTEGRATION_ID not set — skipping post-apply sync" >&2
      exit 0
    fi
    echo "==> Trigger integration sync (integration_id=${INTEGRATION_ID})" >&2
    python3 "$root/scripts/trigger_sync.py"
    ;;
  destroy-lifecycle)
    account_id="$(resolve_aws_account_id)"
    if [[ -z "$account_id" ]]; then
      echo "AWS_ACCOUNT_ID is required in .env" >&2
      exit 1
    fi
    cred_file="$(mktemp)"
    trap 'rm -f "$cred_file"' EXIT
    write_aws_credentials_file "$cred_file"

    echo "==> Terraform destroy (role + harness)" >&2
    cd "$root/terraform/bedrock"
    terraform init -input=false
    terraform destroy -auto-approve \
      -var="aws_credentials_file=${cred_file}" \
      -var="aws_account_id=${account_id}" \
      -var="aws_region=${AWS_REGION:-us-east-1}" \
      -var="agent_name=${AGENT_NAME:-demo-support-agent}" \
      -var="agent_backend=${AGENT_BACKEND:-agentcore}" \
      "$@"

    backend_lc="$(printf '%s' "${AGENT_BACKEND:-agentcore}" | tr '[:upper:]' '[:lower:]')"
    if [[ "$backend_lc" == "agentcore" ]]; then
      echo "==> AgentCore memory cleanup" >&2
      "$root/scripts/cleanup-agentcore-memory.sh"
    fi
    ;;
  apply-bedrock)
    account_id="$(resolve_aws_account_id)"
    if [[ -z "$account_id" ]]; then
      echo "AWS_ACCOUNT_ID is required in .env" >&2
      exit 1
    fi
    cred_file="$(mktemp)"
    trap 'rm -f "$cred_file"' EXIT
    write_aws_credentials_file "$cred_file"

    echo "==> BalkanID gate (gate.py)" >&2
    python3 "$root/scripts/gate.py"

    backend_lc="$(printf '%s' "${AGENT_BACKEND:-agentcore}" | tr '[:upper:]' '[:lower:]')"
    if [[ "$backend_lc" == "agentcore" ]]; then
      echo "==> AgentCore pre-apply reconciliation (orphan harness/role/memory from prior failed creates)" >&2
      "$root/scripts/cleanup-agentcore-before-apply.sh"
    fi

    echo "==> Terraform Bedrock stack (backend=${AGENT_BACKEND:-agentcore})" >&2
    cd "$root/terraform/bedrock"
    terraform init -input=false
    terraform apply -auto-approve \
      -var="aws_credentials_file=${cred_file}" \
      -var="aws_account_id=${account_id}" \
      -var="aws_region=${AWS_REGION:-us-east-1}" \
      -var="agent_name=${AGENT_NAME:-demo-support-agent}" \
      -var="agent_backend=${AGENT_BACKEND:-agentcore}" \
      "$@"

    trigger_lc="$(printf '%s' "${TRIGGER_INTEGRATION_SYNC:-true}" | tr '[:upper:]' '[:lower:]')"
    case "$trigger_lc" in
      0|false|no|off)
        echo "==> TRIGGER_INTEGRATION_SYNC disabled; skipping sync" >&2
        exit 0
        ;;
    esac
    if [[ -z "${INTEGRATION_ID:-}" ]]; then
      echo "==> INTEGRATION_ID not set — skipping post-apply sync" >&2
      exit 0
    fi
    echo "==> Trigger integration sync (integration_id=${INTEGRATION_ID})" >&2
    python3 "$root/scripts/trigger_sync.py"
    ;;
  apply-gate)
    cd "$root/terraform"
    terraform init -input=false
    exec terraform apply -auto-approve "${gate_apply_vars[@]}" "$@"
    ;;
  plan-bedrock)
    account_id="$(resolve_aws_account_id)"
    if [[ -z "$account_id" ]]; then
      echo "AWS_ACCOUNT_ID is required in .env" >&2
      exit 1
    fi
    cred_file="$(mktemp)"
    trap 'rm -f "$cred_file"' EXIT
    write_aws_credentials_file "$cred_file"
    cd "$root/terraform/bedrock"
    terraform init -input=false
    exec terraform plan \
      -var="aws_credentials_file=${cred_file}" \
      -var="aws_account_id=${account_id}" \
      -var="aws_region=${AWS_REGION:-us-east-1}" \
      -var="agent_name=${AGENT_NAME:-demo-support-agent}" \
      -var="agent_backend=${AGENT_BACKEND:-agentcore}" \
      "$@"
    ;;
  destroy-bedrock)
    account_id="$(resolve_aws_account_id)"
    if [[ -z "$account_id" ]]; then
      echo "AWS_ACCOUNT_ID is required in .env" >&2
      exit 1
    fi
    cred_file="$(mktemp)"
    trap 'rm -f "$cred_file"' EXIT
    write_aws_credentials_file "$cred_file"
    cd "$root/terraform/bedrock"
    terraform init -input=false
    terraform destroy -auto-approve \
      -var="aws_credentials_file=${cred_file}" \
      -var="aws_account_id=${account_id}" \
      -var="aws_region=${AWS_REGION:-us-east-1}" \
      -var="agent_name=${AGENT_NAME:-demo-support-agent}" \
      -var="agent_backend=${AGENT_BACKEND:-agentcore}" \
      "$@"

    backend_lc="$(printf '%s' "${AGENT_BACKEND:-agentcore}" | tr '[:upper:]' '[:lower:]')"
    if [[ "$backend_lc" == "agentcore" ]]; then
      echo "==> AgentCore memory cleanup (orphans after harness destroy)" >&2
      "$root/scripts/cleanup-agentcore-memory.sh"
    fi
    ;;
  cleanup-agentcore-memory)
    exec "$root/scripts/cleanup-agentcore-memory.sh" "$@"
    ;;
  cleanup-agentcore-before-apply)
    exec "$root/scripts/cleanup-agentcore-before-apply.sh" "$@"
    ;;
  *)
    echo "Usage: $0 {apply-bedrock|apply-lifecycle|destroy-lifecycle|apply-gate|plan-bedrock|destroy-bedrock|cleanup-agentcore-memory|cleanup-agentcore-before-apply}" >&2
    exit 1
    ;;
esac
