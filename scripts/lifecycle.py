#!/usr/bin/env python3
"""EN-8896: JIT identity lifecycle — approval gates, Terraform provisions AWS.

BalkanID requests record policy intent; this script waits for **approval only**
(not provisioner completion). Terraform creates the IAM role, policies, and harness.

Apply:
  1. CREATE_SERVICE_ACCOUNT (optional grants in scimPayload)
  2. SERVICE_ACCOUNT_ASSIGNMENT (optional; requires LIFECYCLE_IDENTITY_ID if set)
  3. AGENT_ACCESS

Teardown is Terraform destroy (see terraform-local.sh destroy-lifecycle / CD destroy).

No third-party packages.
"""

from __future__ import annotations

import json
import os
import sys

from balkanid_api import (
    api_client_from_env,
    ci_mode,
    create_request,
    env,
    env_optional,
    load_dotenv,
    log_stderr,
    poll_request,
    redact_identifier,
)

PHASE_CREATE = "create_service_account"
PHASE_ASSIGN = "assign_service_account"
PHASE_AGENT = "agent_access"

ROLE_PATH_PREFIX = "/balkanid-agent-lifecycle/"


def poll_settings() -> tuple[int, int]:
    poll_s = int(os.environ.get("POLL_SECONDS", "5"))
    timeout_s = int(os.environ.get("POLL_TIMEOUT_SECONDS", "900"))
    return poll_s, timeout_s


def lifecycle_reason(suffix: str) -> str:
    base = env_optional("LIFECYCLE_REASON", env_optional("AGENT_PURPOSE", "Agent lifecycle via Terraform"))
    agent = env_optional("AGENT_NAME", "demo-support-agent")
    return f"{base} — {suffix} for agent {agent}"


def duration_input() -> dict:
    out: dict = {}
    duration_raw = env_optional("LIFECYCLE_DURATION_SECONDS")
    if duration_raw:
        out["duration"] = int(duration_raw)
    expiration = env_optional("LIFECYCLE_EXPIRATION_DATE")
    if expiration:
        out["expirationDate"] = expiration
    return out


def entity_base(integration_id: str) -> dict:
    return {
        "provisioningOption": "app",
        "integrationId": integration_id,
        "sourceType": "aws service role",
        "identityType": "service account",
    }


def policy_grants() -> list[dict]:
    policy_name = env_optional("LIFECYCLE_POLICY_NAME")
    if not policy_name:
        return []
    grants = [{"type": "policy", "source_name": policy_name}]
    policy_id = env_optional("LIFECYCLE_POLICY_ID")
    if policy_id:
        grants = [{"type": "policy", "source_id": policy_id, "source_name": policy_name}]
    return grants


def expected_role_arn(role_name: str, aws_account_id: str) -> str:
    override = env_optional("INTENDED_IAM_ROLE_ARN")
    if override:
        return override
    return f"arn:aws:iam::{aws_account_id}:role{ROLE_PATH_PREFIX}{role_name}"


def create_service_account_input(owner: str, integration_id: str, role_name: str) -> dict:
    scim_payload: dict = {
        "aws_service_role_name": role_name,
        "aws_service_names": env_optional(
            "LIFECYCLE_AWS_SERVICE_NAMES",
            "bedrock-agentcore.amazonaws.com",
        ),
        "description": env_optional(
            "LIFECYCLE_ROLE_DESCRIPTION",
            "AgentCore execution role (Terraform-provisioned after approval)",
        ),
    }
    grants = policy_grants()
    if grants:
        scim_payload["grants"] = grants
        scim_payload["revokes"] = []

    return {
        "requestType": "CREATE_SERVICE_ACCOUNT",
        "employeeEmail": owner,
        "reason": lifecycle_reason("create service role"),
        **duration_input(),
        "payload": {
            "entity": {
                **entity_base(integration_id),
                "name": role_name,
                "scimPayload": scim_payload,
            }
        },
    }


def assign_service_account_input(integration_id: str, identity_id: str, role_name: str) -> dict:
    grants = policy_grants()
    if not grants:
        raise SystemExit("LIFECYCLE_POLICY_NAME is required for SERVICE_ACCOUNT_ASSIGNMENT")

    return {
        "requestType": "SERVICE_ACCOUNT_ASSIGNMENT",
        "reason": lifecycle_reason("assign entitlements"),
        **duration_input(),
        "payload": {
            "entity": {
                **entity_base(integration_id),
                "entity": identity_id,
                "name": role_name,
                "scimPayload": {
                    "grants": grants,
                    "revokes": [],
                },
            }
        },
    }


def agent_access_input(owner: str, integration_id: str, agent_name: str, role_arn: str) -> dict:
    agent_type = env_optional("AGENT_TYPE", "terraform")
    agent_access: dict = {
        "action": "CREATE",
        "name": agent_name,
        "agentType": agent_type,
        "intendedIamRoleArn": role_arn,
    }
    if integration_id:
        agent_access["integrationId"] = integration_id

    return {
        "requestType": "AGENT_ACCESS",
        "employeeEmail": owner,
        "reason": lifecycle_reason("agent access"),
        "runAsync": False,
        "payload": {"agentAccess": agent_access},
    }


def wait_for_approval(
    url: str,
    key_id: str,
    secret: str,
    request_id: str,
    *,
    poll_s: int,
    timeout_s: int,
    label: str,
) -> dict:
    return poll_request(
        url,
        key_id,
        secret,
        request_id,
        wait_provisioning=False,
        poll_s=poll_s,
        timeout_s=timeout_s,
        label=label,
    )


def write_state(path: str, payload: dict) -> None:
    with open(path, encoding="utf-8", mode="w") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")
    log_stderr(f"wrote lifecycle state to {path}")


def phase_apply(phase: str) -> int:
    load_dotenv()
    url, key_id, secret = api_client_from_env()
    owner = env("BALKANID_AGENT_OWNER_EMAIL")
    integration_id = env("INTEGRATION_ID")
    role_name = env_optional("LIFECYCLE_ROLE_NAME") or env_optional("AGENT_NAME", "demo-support-agent")
    agent_name = env_optional("AGENT_NAME", role_name)
    aws_account_id = env("AWS_ACCOUNT_ID")
    poll_s, timeout_s = poll_settings()
    state_path = env_optional("LIFECYCLE_STATE_FILE", ".lifecycle_state.json")
    role_arn = expected_role_arn(role_name, aws_account_id)

    if ci_mode():
        log_stderr(f"lifecycle phase={phase} owner={redact_identifier(owner)} role={role_name!r}")
    else:
        log_stderr(f"lifecycle phase={phase} owner={owner!r} role={role_name!r}")

    state: dict = {"role_name": role_name, "expected_role_arn": role_arn}
    if os.path.isfile(state_path):
        with open(state_path, encoding="utf-8") as fh:
            state.update(json.load(fh))

    if phase in (PHASE_CREATE, "apply-all"):
        req_id = create_request(url, key_id, secret, create_service_account_input(owner, integration_id, role_name))
        wait_for_approval(
            url,
            key_id,
            secret,
            req_id,
            poll_s=poll_s,
            timeout_s=timeout_s,
            label="CREATE_SERVICE_ACCOUNT",
        )
        state["create_request_id"] = req_id
        write_state(state_path, state)
        if phase == PHASE_CREATE:
            print(json.dumps(state))
            return 0

    identity_id = env_optional("LIFECYCLE_IDENTITY_ID") or state.get("identity_id")
    include_assign = env_optional("LIFECYCLE_INCLUDE_ASSIGN_REQUEST", "false").lower() in ("1", "true", "yes")
    if include_assign and not identity_id:
        log_stderr(
            "LIFECYCLE_INCLUDE_ASSIGN_REQUEST=true but no LIFECYCLE_IDENTITY_ID — "
            "skipping SERVICE_ACCOUNT_ASSIGNMENT (grants are on CREATE request)"
        )
        include_assign = False

    if phase in (PHASE_ASSIGN, "apply-all") and include_assign:
        req_id = create_request(
            url,
            key_id,
            secret,
            assign_service_account_input(integration_id, identity_id, role_name),
        )
        wait_for_approval(
            url,
            key_id,
            secret,
            req_id,
            poll_s=poll_s,
            timeout_s=timeout_s,
            label="SERVICE_ACCOUNT_ASSIGNMENT",
        )
        state["assign_request_id"] = req_id
        write_state(state_path, state)
        if phase == PHASE_ASSIGN:
            print(json.dumps(state))
            return 0

    if phase in (PHASE_AGENT, "apply-all"):
        req_id = create_request(
            url,
            key_id,
            secret,
            agent_access_input(owner, integration_id, agent_name, role_arn),
        )
        wait_for_approval(
            url,
            key_id,
            secret,
            req_id,
            poll_s=poll_s,
            timeout_s=timeout_s,
            label="AGENT_ACCESS",
        )
        state["agent_request_id"] = req_id
        write_state(state_path, state)
        print(json.dumps(state))
        return 0

    raise SystemExit(f"unknown apply phase: {phase}")


def main() -> int:
    if len(sys.argv) < 2:
        raise SystemExit(
            "usage: lifecycle.py {apply-all|create-service-account|assign|agent-access}"
        )
    cmd = sys.argv[1].strip().lower()
    mapping = {
        "apply-all": "apply-all",
        "create-service-account": PHASE_CREATE,
        "assign": PHASE_ASSIGN,
        "agent-access": PHASE_AGENT,
    }
    if cmd not in mapping:
        raise SystemExit(f"unknown command: {cmd}")
    return phase_apply(mapping[cmd])


if __name__ == "__main__":
    sys.exit(main())
