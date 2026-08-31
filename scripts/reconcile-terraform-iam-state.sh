#!/usr/bin/env bash
# Normalize cached Terraform IAM addresses and drop stale entries Terraform cannot refresh.
# Sourced by cleanup-agentcore-before-apply.sh (requires tf_dir, state_has, aws_cli, etc.).
set -euo pipefail

IAM_ROLE_RESOURCES=(
  'aws_iam_role.execution[0]'
  'aws_iam_role.agentcore[0]'
  'aws_iam_role.bedrock_classic[0]'
)
IAM_POLICY_RESOURCES=(
  'aws_iam_role_policy.invoke[0]'
  'aws_iam_role_policy.agentcore_invoke[0]'
  'aws_iam_role_policy.bedrock_classic_invoke[0]'
)

purge_all_iam_from_state() {
  local resource
  for resource in "${IAM_ROLE_RESOURCES[@]}" "${IAM_POLICY_RESOURCES[@]}"; do
    if state_has "$resource"; then
      echo "  -> terraform state rm ${resource}"
      (cd "$tf_dir" && terraform state rm "$resource")
    fi
  done
}

migrate_legacy_iam_state() {
  if state_has 'aws_iam_role.execution[0]'; then
    :
  elif state_has 'aws_iam_role.agentcore[0]'; then
    echo "Migrating state aws_iam_role.agentcore[0] -> aws_iam_role.execution[0]"
    (cd "$tf_dir" && terraform state mv 'aws_iam_role.agentcore[0]' 'aws_iam_role.execution[0]')
  elif state_has 'aws_iam_role.bedrock_classic[0]'; then
    echo "Migrating state aws_iam_role.bedrock_classic[0] -> aws_iam_role.execution[0]"
    (cd "$tf_dir" && terraform state mv 'aws_iam_role.bedrock_classic[0]' 'aws_iam_role.execution[0]')
  fi

  if state_has 'aws_iam_role_policy.invoke[0]'; then
    :
  elif state_has 'aws_iam_role_policy.agentcore_invoke[0]'; then
    echo "Migrating state aws_iam_role_policy.agentcore_invoke[0] -> aws_iam_role_policy.invoke[0]"
    (cd "$tf_dir" && terraform state mv 'aws_iam_role_policy.agentcore_invoke[0]' 'aws_iam_role_policy.invoke[0]')
  elif state_has 'aws_iam_role_policy.bedrock_classic_invoke[0]'; then
    echo "Migrating state aws_iam_role_policy.bedrock_classic_invoke[0] -> aws_iam_role_policy.invoke[0]"
    (cd "$tf_dir" && terraform state mv 'aws_iam_role_policy.bedrock_classic_invoke[0]' 'aws_iam_role_policy.invoke[0]')
  fi
}

# Drop IAM state Terraform cannot refresh (wrong path, deleted role, or unreadable name collision).
reconcile_terraform_iam_state() {
  local status="${1:-}"

  echo "==> Terraform IAM state reconciliation"
  migrate_legacy_iam_state

  case "$status" in
    lifecycle)
      echo "IAM role ${role_name} verified under ${role_path} — keeping Terraform state."
      ;;
    absent|unverified)
      echo "IAM role ${role_name} is ${status} — purging IAM resources from Terraform state (apply will recreate)."
      purge_all_iam_from_state
      ;;
    *)
      if [[ "$status" == outside\|* ]]; then
        echo "IAM role ${role_name} is outside ${role_path} — purging IAM from state (apply will recreate under lifecycle path)."
        purge_all_iam_from_state
      else
        echo "warning: unknown IAM status '${status}' — purging IAM from state to avoid refresh errors." >&2
        purge_all_iam_from_state
      fi
      ;;
  esac
}
