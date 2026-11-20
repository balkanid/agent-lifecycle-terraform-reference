#!/usr/bin/env python3
"""Create a BalkanID service account request (CREATE_SERVICE_ACCOUNT) and wait for a decision.

Approves the agent's own AWS IAM execution role before Terraform creates it. This gate only
approves; it does not wait on BalkanID provisioning. LIFECYCLE_TARGET picks the payload:

  bedrock             (default) role SERVICE_ACCOUNT_ROLE_NAME (or AGENT_NAME) under
                      /balkanid-agent-lifecycle/, one policy grant, optional duration/expiry
  bedrock-guardrails  role agent-<AGENT_NAME> under /balkanid-agents/, the reviewed
                      AGENT_POLICY_NAMES, and the agent's approved expiry

For a Copilot agent's Entra identity use scripts/entra_agent_identity_gate.py instead.
Exit codes as in gate.py. Requires env vars from env.example. Standard library only.
"""

from __future__ import annotations

import json
import sys

import balkanid_api as api

ROLE_PATH_PREFIX = "/balkanid-agent-lifecycle/"


# --- bedrock (the CI demo) ------------------------------------------------------------------


def gate_reason() -> str:
    base = api.env_optional("SERVICE_ACCOUNT_PURPOSE", api.env_optional("AGENT_PURPOSE", "Service role via Terraform"))
    role = api.env_optional("SERVICE_ACCOUNT_ROLE_NAME") or api.env_optional("AGENT_NAME", "demo-support-agent")
    return f"{base} — create service role for {role}"


def duration_input() -> dict:
    out: dict = {}
    duration_raw = api.env_optional("SERVICE_ACCOUNT_DURATION_SECONDS") or api.env_optional("LIFECYCLE_DURATION_SECONDS")
    if duration_raw:
        out["duration"] = int(duration_raw)
    expiration = api.env_optional("SERVICE_ACCOUNT_EXPIRATION_DATE") or api.env_optional("LIFECYCLE_EXPIRATION_DATE")
    if expiration:
        out["expirationDate"] = expiration
    return out


def policy_grants() -> list[dict]:
    policy_name = api.env_optional("SERVICE_ACCOUNT_POLICY_NAME") or api.env_optional("LIFECYCLE_POLICY_NAME")
    if not policy_name:
        return []
    policy_id = api.env_optional("SERVICE_ACCOUNT_POLICY_ID") or api.env_optional("LIFECYCLE_POLICY_ID")
    if policy_id:
        return [{"type": "policy", "source_id": policy_id, "source_name": policy_name}]
    return [{"type": "policy", "source_name": policy_name}]


def entity_payload(integration_id: str, role_name: str, scim_payload: dict) -> dict:
    # No identityType: the CREATE_SERVICE_ACCOUNT request type decides it.
    return {
        "entity": {
            "provisioningOption": "app",
            "integrationId": integration_id,
            "sourceType": "aws service role",
            "name": role_name,
            "scimPayload": scim_payload,
        }
    }


def create_input(owner: str, integration_id: str, role_name: str) -> dict:
    scim_payload: dict = {
        "aws_service_role_name": role_name,
        "aws_service_names": api.env_optional(
            "SERVICE_ACCOUNT_AWS_SERVICE_NAMES",
            api.env_optional("LIFECYCLE_AWS_SERVICE_NAMES", "bedrock-agentcore.amazonaws.com"),
        ),
        "description": api.env_optional(
            "SERVICE_ACCOUNT_ROLE_DESCRIPTION",
            api.env_optional("LIFECYCLE_ROLE_DESCRIPTION", "AgentCore execution role (Terraform-provisioned after approval)"),
        ),
    }
    grants = policy_grants()
    if grants:
        scim_payload["grants"] = grants
        scim_payload["revokes"] = []
    return {
        "requestType": "CREATE_SERVICE_ACCOUNT",
        "employeeEmail": owner,
        "reason": gate_reason(),
        **duration_input(),
        "payload": entity_payload(integration_id, role_name, scim_payload),
    }


def bedrock_request(owner: str, integration_id: str) -> tuple[dict, str, str]:
    role_name = api.env_optional("SERVICE_ACCOUNT_ROLE_NAME") or api.env_optional("AGENT_NAME", "demo-support-agent")
    role_arn = api.env_optional("INTENDED_IAM_ROLE_ARN")
    account = api.env_optional("AWS_ACCOUNT_ID")
    if not role_arn and account:
        role_arn = f"arn:aws:iam::{account}:role{ROLE_PATH_PREFIX}{role_name}"
    return create_input(owner, integration_id, role_name), role_name, role_arn


# --- bedrock-guardrails (developer-created agents) ------------------------------------------


def guardrails_input(agent: str, owner: str, integration_id: str, policies: list[str], expiration: str) -> dict:
    from policy_check import role_name_for

    role_name = role_name_for(agent)
    scim_payload: dict = {
        "aws_service_role_name": role_name,
        "aws_service_names": api.env_optional("SERVICE_ACCOUNT_AWS_SERVICE_NAMES", "bedrock-agentcore.amazonaws.com"),
        "description": f"Dedicated execution role for agent {agent}; never a developer or human role",
    }
    if policies:
        scim_payload["grants"] = [{"type": "policy", "source_name": p} for p in policies]
        scim_payload["revokes"] = []
    return {
        "requestType": "CREATE_SERVICE_ACCOUNT",
        "employeeEmail": owner,
        "reason": f"Own scoped identity for agent {agent} (expires {expiration})",
        "expirationDate": expiration,
        "payload": entity_payload(integration_id, role_name, scim_payload),
    }


def guardrails_request(owner: str, integration_id: str) -> tuple[dict, str, str]:
    from policy_check import ROLE_PATH, agent_expiry, policy_names, role_name_for

    agent = api.env("AGENT_NAME")
    expiration = agent_expiry()
    policies = policy_names(api.env_optional("AGENT_POLICY_NAMES"))
    role_name = role_name_for(agent)
    account = api.env_optional("AWS_ACCOUNT_ID")
    role_arn = f"arn:aws:iam::{account}:role{ROLE_PATH}{role_name}" if account else ""
    return guardrails_input(agent, owner, integration_id, policies, expiration), role_name, role_arn


def main() -> int:
    api.load_dotenv()
    target = api.lifecycle_target()
    if target == "copilot":
        raise SystemExit("service_account_gate.py gates AWS roles; for Copilot use scripts/entra_agent_identity_gate.py")
    url, key_id, secret = api.api_client_from_env()
    owner = api.env("BALKANID_AGENT_OWNER_EMAIL")
    integration_id = api.env("INTEGRATION_ID")
    build = guardrails_request if target == "bedrock-guardrails" else bedrock_request
    inp, role_name, role_arn = build(owner, integration_id)
    poll_s, timeout_s = api.poll_settings()

    who = api.redact_identifier(owner) if api.ci_mode() else repr(owner)
    api.log_stderr(f"creating service account request target={target} owner={who} role={role_name!r}")

    request_id = ""
    try:
        request_id = api.create_request(url, key_id, secret, inp)
        api.log_stderr(f"request_id={request_id}")
        api.log_stderr("waiting for approval (fail closed on deny/timeout)")
        api.poll_request(
            url,
            key_id,
            secret,
            request_id,
            wait_provisioning=False,
            poll_s=poll_s,
            timeout_s=timeout_s,
            label="CREATE_SERVICE_ACCOUNT",
        )
    except api.ApprovalTimeout as exc:
        api.log_stderr(exc.message)
        print(json.dumps({"request_id": request_id, "status": "timeout"}))
        return 2
    except api.TransportError as exc:
        api.log_stderr(exc.message)
        print(json.dumps({"request_id": request_id, "status": "unreachable"}))
        return 3
    except SystemExit as exc:
        if not isinstance(exc.code, int):
            api.log_stderr(str(exc.code))
        print(json.dumps({"request_id": request_id, "status": "failed"}))
        return exc.code if isinstance(exc.code, int) and exc.code else 1

    out = {"request_id": request_id, "status": "approved", "role_name": role_name}
    if role_arn:
        out["expected_role_arn"] = role_arn
    if inp.get("expirationDate"):
        out["expires_at"] = inp["expirationDate"]
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
