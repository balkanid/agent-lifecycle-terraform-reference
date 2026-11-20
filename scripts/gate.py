#!/usr/bin/env python3
"""Create a BalkanID agent access request (AGENT_ACCESS) and wait until approved or denied.

One gate for every target in this repository; LIFECYCLE_TARGET picks the payload:

  bedrock             (default) AWS Bedrock CI gate: the agent and the IAM role it will run as
  bedrock-guardrails  developer-created agent: owner, requester, parent, policies, expiry
  copilot             Microsoft Copilot Studio agent: environment, solution and Entra identity

Exit codes: 0 approved, 1 denied / partially approved / request failed, 2 approval window
elapsed with no decision, 3 BalkanID Public API unreachable. Fails closed on everything but 0.
Requires env vars from env.example. Standard library only.
"""

from __future__ import annotations

import getpass
import json
import sys

import balkanid_api as api

BEDROCK_ROLE_PATH = "/balkanid-agent-lifecycle/"


# --- bedrock (the CI demo; payload unchanged from the original gate) -----------------------


def expected_role_arn(agent_name: str) -> str:
    override = api.env_optional("INTENDED_IAM_ROLE_ARN")
    if override:
        return override
    aws_account_id = api.env_optional("AWS_ACCOUNT_ID")
    role_name = api.env_optional("SERVICE_ACCOUNT_ROLE_NAME") or agent_name
    if aws_account_id:
        return f"arn:aws:iam::{aws_account_id}:role{BEDROCK_ROLE_PATH}{role_name}"
    return ""


def bedrock_input(owner: str) -> tuple[dict, dict]:
    agent = api.env_optional("AGENT_NAME", "demo-support-agent")
    purpose = api.env_optional("AGENT_PURPOSE", "Agent provisioned via Terraform with BalkanID approval")
    agent_access: dict = {
        "action": "CREATE",
        "name": agent,
        "agentType": api.env_optional("AGENT_TYPE", "terraform"),
    }
    integration = api.env_optional("INTEGRATION_ID")
    if integration:
        agent_access["integrationId"] = integration
    role_arn = expected_role_arn(agent)
    if role_arn:
        agent_access["intendedIamRoleArn"] = role_arn
    inp = {
        "requestType": "AGENT_ACCESS",
        "employeeEmail": owner,
        "reason": purpose or f"Terraform gate for agent {agent}",
        "runAsync": False,
        "payload": {"agentAccess": agent_access},
    }
    return inp, {"agent": agent}


# --- bedrock-guardrails (developer-created agents, scripts/lifecycle.sh) --------------------


def guardrails_input(owner: str) -> tuple[dict, dict]:
    from policy_check import ROLE_PATH, agent_expiry, policy_names, role_name_for

    agent = api.env("AGENT_NAME")
    expiration = agent_expiry()
    purpose = api.env_optional("AGENT_PURPOSE") or f"Developer agent {agent}"
    account = api.env_optional("AWS_ACCOUNT_ID")
    parent = api.env_optional("PARENT_AGENT")
    metadata: dict = {
        "platform": "aws-bedrock-agentcore",
        "requested_by": api.env_optional("GITHUB_ACTOR")
        or api.env_optional("BALKANID_DEVELOPER_ID")
        or getpass.getuser(),
        "expires_at": expiration,
        "policies": policy_names(api.env_optional("AGENT_POLICY_NAMES")),
        "model": api.env_optional("FOUNDATION_MODEL", "amazon.nova-micro-v1:0"),
        "inherits_creator_permissions": False,
    }
    if parent:
        metadata["parent_agent"] = parent
    agent_access: dict = {
        "action": "CREATE",
        "name": agent,
        "agentType": "bedrock-agentcore",
        "description": purpose,
        "metadata": metadata,
    }
    integration = api.env_optional("INTEGRATION_ID")
    if integration:
        agent_access["integrationId"] = integration
    if account:
        agent_access["intendedIamRoleArn"] = f"arn:aws:iam::{account}:role{ROLE_PATH}{role_name_for(agent)}"
    inp = {
        "requestType": "AGENT_ACCESS",
        "employeeEmail": owner,
        "reason": purpose,
        "expirationDate": expiration,
        "runAsync": False,
        "payload": {"agentAccess": agent_access},
    }
    return inp, {"agent": agent, "expires_at": expiration}


# --- copilot (Copilot Studio agent shipped in a Power Platform solution) --------------------


def intended_identity() -> str:
    """Entra identity the agent will run as, when known up front (entra_agent_identity_gate.py)."""
    for name in ("INTENDED_AGENT_IDENTITY_ID", "AGENT_APP_ID", "ENTRA_AGENT_APP_ID"):
        value = api.env_optional(name)
        if value:
            return value
    return ""


def copilot_input(owner: str) -> tuple[dict, dict]:
    agent = api.env_optional("AGENT_NAME", "example-trial-intake-agent")
    purpose = api.env_optional("AGENT_PURPOSE", "Copilot Studio agent provisioned with BalkanID approval")
    # Placement goes in metadata (AgentAccessPayloadInput has no dedicated fields for it),
    # so the approver sees where the agent will land.
    placement = {
        "environmentId": api.env_optional("POWER_PLATFORM_ENVIRONMENT_ID"),
        "solutionUniqueName": api.env_optional("SOLUTION_UNIQUE_NAME"),
        "schemaName": api.env_optional("AGENT_SCHEMA_NAME"),
        "botId": api.env_optional("AGENT_BOT_ID"),
        "intendedIdentityId": intended_identity(),
    }
    metadata = {"platform": "microsoft-copilot-studio", **{k: v for k, v in placement.items() if v}}
    agent_access: dict = {
        "action": "CREATE",
        "name": agent,
        "agentType": api.env_optional("AGENT_TYPE", "copilot-studio"),
        "description": purpose,
        "metadata": metadata,
    }
    integration = api.env_optional("INTEGRATION_ID")
    if integration:
        agent_access["integrationId"] = integration
    inp = {
        "requestType": "AGENT_ACCESS",
        "employeeEmail": owner,
        "reason": purpose or f"Copilot agent gate for {agent}",
        "runAsync": False,
        "payload": {"agentAccess": agent_access},
    }
    return inp, {"agent": agent}


BUILDERS = {"bedrock": bedrock_input, "bedrock-guardrails": guardrails_input, "copilot": copilot_input}


def build_input(target: str, owner: str) -> tuple[dict, dict]:
    return BUILDERS[target](owner)


def main() -> int:
    api.load_dotenv()
    target = api.lifecycle_target()
    url, key_id, secret = api.api_client_from_env()
    owner = api.env_optional("BALKANID_AGENT_OWNER_EMAIL")
    if not owner:
        raise SystemExit("missing required env BALKANID_AGENT_OWNER_EMAIL")
    inp, summary = build_input(target, owner)
    poll_s, timeout_s = api.poll_settings()
    agent = summary["agent"]

    if api.ci_mode():
        api.log_stderr("public API url=(redacted in CI)")
        api.log_stderr(f"creating agent access request target={target} owner={api.redact_identifier(owner)} agent={agent!r}")
    else:
        api.log_stderr(f"public API url={url}")
        api.log_stderr(f"creating agent access request target={target} owner={owner!r} agent={agent!r}")

    # create_request is inside the try: a network failure must report as unreachable, not denied.
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
            label="AGENT_ACCESS",
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
        if isinstance(exc.code, int):
            code, status = (exc.code or 1), ("denied" if exc.code in (None, 0, 1) else "failed")
        else:
            api.log_stderr(str(exc.code))
            code, status = 1, "failed"
        print(json.dumps({"request_id": request_id, "status": status}))
        return code

    if target == "copilot":
        api.record_approved_scope(
            {
                "agent_request_id": request_id,
                "agent_name": agent,
                "copilot_surface": "copilot-studio",
                "environment_id": api.env_optional("POWER_PLATFORM_ENVIRONMENT_ID"),
                "solution_unique_name": api.env_optional("SOLUTION_UNIQUE_NAME"),
                # publish_copilot_agent.py targets AGENT_SCHEMA_NAME, else AGENT_BOT_ID.
                "agent_schema_name": api.env_optional("AGENT_SCHEMA_NAME"),
                "agent_bot_id": api.env_optional("AGENT_BOT_ID"),
            }
        )

    print(json.dumps({"request_id": request_id, "status": "approved", **summary}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
