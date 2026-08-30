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
[pov]
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
  -var="agent_purpose=${AGENT_PURPOSE:-Demo agent lifecycle PoV}"
  -var="intended_iam_role_arn=${INTENDED_IAM_ROLE_ARN:-}"
)

cmd="${1:-}"
shift || true

case "$cmd" in
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

    echo "==> Terraform Bedrock stack" >&2
    cd "$root/terraform/bedrock"
    terraform init -input=false
    exec terraform apply -auto-approve \
      -var="aws_credentials_file=${cred_file}" \
      -var="aws_account_id=${account_id}" \
      -var="aws_region=${AWS_REGION:-us-east-1}" \
      -var="agent_name=${AGENT_NAME:-demo-support-agent}" \
      -var="agent_backend=${AGENT_BACKEND:-agentcore}" \
      "$@"
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
    exec terraform destroy -auto-approve \
      -var="aws_credentials_file=${cred_file}" \
      -var="aws_account_id=${account_id}" \
      -var="aws_region=${AWS_REGION:-us-east-1}" \
      -var="agent_name=${AGENT_NAME:-demo-support-agent}" \
      -var="agent_backend=${AGENT_BACKEND:-agentcore}" \
      "$@"
    ;;
  *)
    echo "Usage: $0 {apply-bedrock|apply-gate|plan-bedrock|destroy-bedrock}" >&2
    exit 1
    ;;
esac
