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

# One absolute path for the approval record, used unchanged by the cleanup below, the gates
# (which write it) and verify_approved_scope.py (which reads it). Empty disables the record.
APPROVED_SCOPE_FILE="${APPROVED_SCOPE_FILE-.approved-scope.json}"
if [[ -n "$APPROVED_SCOPE_FILE" && "$APPROVED_SCOPE_FILE" != /* ]]; then
  APPROVED_SCOPE_FILE="$root/${APPROVED_SCOPE_FILE#./}"
fi
export APPROVED_SCOPE_FILE

# The Entra identity name the identity gate approves (entra_agent_identity_gate.py).
identity_display_name="${ENTRA_IDENTITY_DISPLAY_NAME:-${AGENT_NAME:-example-trial-intake-agent}}"

identity_state_exists() {
  [[ -n "$(terraform -chdir="$root/terraform/entra-agent-identity" state list 2>/dev/null || true)" ]]
}

run_gates() {
  # Start from a clean record so a previous run's approval cannot satisfy this one.
  if [[ -n "$APPROVED_SCOPE_FILE" ]]; then
    rm -f "$APPROVED_SCOPE_FILE"
  fi

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
    export TF_VAR_agent_name="$identity_display_name"
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
    # was approved. An identity named up front (same order as gate.py) must match it.
    intended_id="${INTENDED_AGENT_IDENTITY_ID:-${AGENT_APP_ID:-${ENTRA_AGENT_APP_ID:-}}}"
    recovered_id="$(terraform -chdir="$root/terraform/entra-agent-identity" output -raw application_id 2>/dev/null || true)"
    if [[ -n "$intended_id" && -n "$recovered_id" && "$intended_id" != "$recovered_id" ]]; then
      echo "the approved identity ($intended_id) differs from the one in terraform/entra-agent-identity state ($recovered_id); refusing to bind it" >&2
      exit 1
    fi
    AGENT_APP_ID="${intended_id:-$recovered_id}"
    export AGENT_APP_ID
    [[ -n "${AGENT_APP_ID:-}" ]] && echo "==> agent identity app_id=${AGENT_APP_ID}" >&2

    terraform_copilot_studio apply
    publish_agent
    sync_balkanid
    ;;

  destroy-lifecycle)
    CD_OPERATION=destroy python3 "$root/scripts/preflight.py"
    terraform_copilot_studio destroy
    # Tear down an identity this wrapper created even when PROVISION_AGENT_IDENTITY is not
    # set on the destroy command; only an explicit RETAIN_AGENT_IDENTITY=true keeps it.
    if [[ "${RETAIN_AGENT_IDENTITY:-false}" == "true" ]]; then
      echo "==> RETAIN_AGENT_IDENTITY=true: keeping the Entra agent identity" >&2
    elif [[ "${PROVISION_AGENT_IDENTITY:-false}" == "true" ]] || identity_state_exists; then
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
