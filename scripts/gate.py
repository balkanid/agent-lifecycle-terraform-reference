#!/usr/bin/env python3
"""Create a BalkanID agent access request and wait until approved or denied.

Uses Public API createRequest (requestType: AGENT_ACCESS). Exit 0 only on approval.
Requires env vars from env.example. No third-party packages.
"""

from __future__ import annotations

import json
import sys

from balkanid_api import (
    api_client_from_env,
    ci_mode,
    create_request,
    env_optional,
    load_dotenv,
    log_stderr,
    poll_request,
    poll_settings,
    redact_identifier,
)

ROLE_PATH_PREFIX = "/balkanid-agent-lifecycle/"


def expected_role_arn(agent_name: str) -> str:
    override = env_optional("INTENDED_IAM_ROLE_ARN")
    if override:
        return override
    aws_account_id = env_optional("AWS_ACCOUNT_ID")
    role_name = env_optional("SERVICE_ACCOUNT_ROLE_NAME") or agent_name
    if aws_account_id:
        return f"arn:aws:iam::{aws_account_id}:role{ROLE_PATH_PREFIX}{role_name}"
    return ""


def main() -> int:
    load_dotenv()
    url, key_id, secret = api_client_from_env()
    owner = env_optional("BALKANID_AGENT_OWNER_EMAIL")
    if not owner:
        raise SystemExit("missing required env BALKANID_AGENT_OWNER_EMAIL")

    agent = env_optional("AGENT_NAME", "demo-support-agent")
    agent_type = env_optional("AGENT_TYPE", "terraform")
    integration = env_optional("INTEGRATION_ID")
    purpose = env_optional("AGENT_PURPOSE", "Agent provisioned via Terraform with BalkanID approval")
    role_arn = expected_role_arn(agent)
    poll_s, timeout_s = poll_settings()

    reason = purpose or f"Terraform gate for agent {agent}"

    if ci_mode():
        log_stderr("public API url=(redacted in CI)")
        log_stderr(f"creating agent access request owner={redact_identifier(owner)} agent={agent!r}")
    else:
        log_stderr(f"public API url={url}")
        log_stderr(f"creating agent access request owner={owner!r} agent={agent!r}")

    agent_access: dict = {
        "action": "CREATE",
        "name": agent,
        "agentType": agent_type,
    }
    if integration:
        agent_access["integrationId"] = integration
    if role_arn:
        agent_access["intendedIamRoleArn"] = role_arn

    inp: dict = {
        "requestType": "AGENT_ACCESS",
        "employeeEmail": owner,
        "reason": reason,
        "runAsync": False,
        "payload": {"agentAccess": agent_access},
    }

    request_id = create_request(url, key_id, secret, inp)
    log_stderr(f"request_id={request_id}")
    log_stderr("waiting for approval (fail closed on deny/timeout)")

    try:
        poll_request(
            url,
            key_id,
            secret,
            request_id,
            wait_provisioning=False,
            poll_s=poll_s,
            timeout_s=timeout_s,
            label="AGENT_ACCESS",
        )
    except SystemExit as exc:
        code = exc.code if isinstance(exc.code, int) else 1
        print(json.dumps({"request_id": request_id, "status": "denied" if code == 1 else "failed"}), file=sys.stderr)
        return code or 1

    print(json.dumps({"request_id": request_id, "status": "approved"}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
