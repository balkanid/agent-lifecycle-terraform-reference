#!/usr/bin/env bash
# Local wrapper for the Microsoft Copilot Studio path: sources .env, runs the gates in
# order, then the Terraform stacks. Not run end-to-end against a live Microsoft tenant.
#
#   ./scripts/copilot-local.sh gate               gates only, no Microsoft credentials
#   ./scripts/copilot-local.sh apply-lifecycle    gates + verify scope + provision + sync
#   ./scripts/copilot-local.sh destroy-lifecycle  tear the Terraform stacks down
#
# Secrets are passed to Terraform and the scripts through the environment (TF_VAR_*),
# never on a command line.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
export LIFECYCLE_TARGET=copilot

if [[ ! -f "$root/.env" ]]; then
  echo "no .env found - copy env.example to .env and fill it in" >&2
  exit 1
fi

# Load .env WITHOUT clobbering anything the caller set inline, so that
# `ENTRA_IDENTITY_GATE=true ./scripts/copilot-local.sh gate` does what it says.
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
  key="${line%%=*}"
  key="${key// /}"
  [[ -z "$key" ]] && continue
  if [[ -z "${!key:-}" ]]; then
    value="${line#*=}"
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    export "$key=$value"
  fi
done < "$root/.env"
export LIFECYCLE_TARGET=copilot

if [[ -n "${SOLUTION_ZIP_PATH:-}" && "$SOLUTION_ZIP_PATH" != /* ]]; then
  SOLUTION_ZIP_PATH="$root/${SOLUTION_ZIP_PATH#./}"
  export SOLUTION_ZIP_PATH
fi

run_gates() {
  # Start from a clean record so a previous run's approval cannot satisfy this one.
  rm -f "$root/${APPROVED_SCOPE_FILE:-.approved-scope.json}"

  if [[ "${ENTRA_IDENTITY_GATE:-false}" == "true" ]]; then
    echo "==> Entra identity gate" >&2
    python3 "$root/scripts/entra_agent_identity_gate.py"
  fi

  if [[ "${AGENT_GATE:-true}" == "true" ]]; then
    echo "==> Agent access gate" >&2
    python3 "$root/scripts/gate.py"
  fi
}

verify_scope() {
  if [[ "${VERIFY_APPROVED_SCOPE:-true}" != "true" ]]; then
    echo "==> Approved-scope verification disabled" >&2
    return 0
  fi
  echo "==> Verifying the environment matches what was approved" >&2
  python3 "$root/scripts/verify_approved_scope.py"
}

# Terraform credentials as TF_VAR_* environment variables, scoped to a subshell.
terraform_identity() {
  echo "==> Terraform: Entra agent identity" >&2
  (
    export TF_VAR_tenant_id="${AZURE_TENANT_ID}"
    export TF_VAR_client_id="${AZURE_CLIENT_ID}"
    export TF_VAR_client_secret="${AZURE_CLIENT_SECRET}"
    export TF_VAR_agent_name="${AGENT_NAME:-example-trial-intake-agent}"
    TF_VAR_graph_application_permissions="$(python3 -c 'import os, json; print(json.dumps([p.strip() for p in os.environ.get("ENTRA_GRAPH_PERMISSIONS", "").split(",") if p.strip()]))')"
    export TF_VAR_graph_application_permissions
    terraform -chdir="$root/terraform/entra-agent-identity" init -input=false
    terraform -chdir="$root/terraform/entra-agent-identity" "$1" -auto-approve
  )
}

terraform_copilot_studio() {
  echo "==> Terraform: Copilot Studio stack" >&2
  (
    export TF_VAR_tenant_id="${AZURE_TENANT_ID}"
    export TF_VAR_client_id="${AZURE_CLIENT_ID}"
    export TF_VAR_client_secret="${AZURE_CLIENT_SECRET}"
    export TF_VAR_environment_id="${POWER_PLATFORM_ENVIRONMENT_ID}"
    export TF_VAR_solution_unique_name="${SOLUTION_UNIQUE_NAME:-BalkanIDAgentLifecycle}"
    export TF_VAR_solution_version="${SOLUTION_VERSION:-1.0.0.0}"
    export TF_VAR_agent_schema_name="${AGENT_SCHEMA_NAME:-}"
    # Publishing runs as its own visible step (publish_agent below), not inside Terraform.
    export TF_VAR_publish_agent=false
    [[ -n "${SOLUTION_ZIP_PATH:-}" ]] && export TF_VAR_solution_zip_path="${SOLUTION_ZIP_PATH}"
    [[ -n "${AGENT_APP_ID:-}" ]] && export TF_VAR_agent_application_id="${AGENT_APP_ID}"
    terraform -chdir="$root/terraform/copilot-studio" init -input=false
    terraform -chdir="$root/terraform/copilot-studio" "$1" -auto-approve
  )
}

publish_agent() {
  if [[ "${PUBLISH_AGENT:-false}" == "true" ]]; then
    echo "==> Publishing the agent" >&2
    python3 "$root/scripts/publish_copilot_agent.py"
  fi
}

sync_balkanid() {
  if [[ "${TRIGGER_INTEGRATION_SYNC:-true}" == "true" ]]; then
    echo "==> BalkanID integration sync" >&2
    python3 "$root/scripts/trigger_sync.py"
  fi
}

cmd="${1:-}"
shift || true

case "$cmd" in
  gate)
    python3 "$root/scripts/preflight.py"
    run_gates
    echo "==> approved" >&2
    ;;

  apply-lifecycle)
    python3 "$root/scripts/preflight.py"
    run_gates
    verify_scope

    if [[ "${PROVISION_AGENT_IDENTITY:-false}" == "true" ]]; then
      terraform_identity apply
    fi

    # Recover the agent's app id from the identity stack whenever that state exists, not
    # only on the run that created it. Otherwise a second apply-lifecycle drops
    # powerplatform_environment_application_admin and quietly unbinds the identity that
    # was approved.
    if [[ -z "${AGENT_APP_ID:-}" ]]; then
      AGENT_APP_ID="$(terraform -chdir="$root/terraform/entra-agent-identity" output -raw application_id 2>/dev/null || true)"
      export AGENT_APP_ID
    fi
    [[ -n "${AGENT_APP_ID:-}" ]] && echo "==> agent identity app_id=${AGENT_APP_ID}" >&2

    terraform_copilot_studio apply
    publish_agent
    sync_balkanid
    ;;

  destroy-lifecycle)
    CD_OPERATION=destroy python3 "$root/scripts/preflight.py"
    terraform_copilot_studio destroy
    if [[ "${PROVISION_AGENT_IDENTITY:-false}" == "true" ]]; then
      terraform_identity destroy
    fi
    ;;

  *)
    cat >&2 <<'USAGE'
usage: ./scripts/copilot-local.sh <command>

  gate                gates only - no Microsoft credentials needed
  apply-lifecycle     identity gate + agent gate + verify scope + provisioning + sync
  destroy-lifecycle   tear the Terraform stacks down
USAGE
    exit 1
    ;;
esac
