#!/usr/bin/env python3
"""Create a BalkanID service account request and wait until approved or denied.

Uses Public API createRequest (requestType: CREATE_SERVICE_ACCOUNT). Exit 0 only on approval.
Terraform (or your pipeline) provisions the AWS IAM role after approval — this gate does not
wait on BalkanID provisioning.

Requires env vars from env.example. No third-party packages.
"""

from __future__ import annotations

import json
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
    poll_settings,
    redact_identifier,
)

ROLE_PATH_PREFIX = "/balkanid-agent-lifecycle/"


def gate_reason() -> str:
    base = env_optional("SERVICE_ACCOUNT_PURPOSE", env_optional("AGENT_PURPOSE", "Service role via Terraform"))
    role = env_optional("SERVICE_ACCOUNT_ROLE_NAME") or env_optional("AGENT_NAME", "demo-support-agent")
    return f"{base} — create service role for {role}"


def duration_input() -> dict:
    out: dict = {}
    duration_raw = env_optional("SERVICE_ACCOUNT_DURATION_SECONDS") or env_optional("LIFECYCLE_DURATION_SECONDS")
    if duration_raw:
        out["duration"] = int(duration_raw)
    expiration = env_optional("SERVICE_ACCOUNT_EXPIRATION_DATE") or env_optional("LIFECYCLE_EXPIRATION_DATE")
    if expiration:
        out["expirationDate"] = expiration
    return out


def policy_grants() -> list[dict]:
    policy_name = env_optional("SERVICE_ACCOUNT_POLICY_NAME") or env_optional("LIFECYCLE_POLICY_NAME")
    if not policy_name:
        return []
    grants = [{"type": "policy", "source_name": policy_name}]
    policy_id = env_optional("SERVICE_ACCOUNT_POLICY_ID") or env_optional("LIFECYCLE_POLICY_ID")
    if policy_id:
        grants = [{"type": "policy", "source_id": policy_id, "source_name": policy_name}]
    return grants


def create_input(owner: str, integration_id: str, role_name: str) -> dict:
    scim_payload: dict = {
        "aws_service_role_name": role_name,
        "aws_service_names": env_optional(
            "SERVICE_ACCOUNT_AWS_SERVICE_NAMES",
            env_optional("LIFECYCLE_AWS_SERVICE_NAMES", "bedrock-agentcore.amazonaws.com"),
        ),
        "description": env_optional(
            "SERVICE_ACCOUNT_ROLE_DESCRIPTION",
            env_optional(
                "LIFECYCLE_ROLE_DESCRIPTION",
                "AgentCore execution role (Terraform-provisioned after approval)",
            ),
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
        "payload": {
            "entity": {
                "provisioningOption": "app",
                "integrationId": integration_id,
                "sourceType": "aws service role",
                "identityType": "service account",
                "name": role_name,
                "scimPayload": scim_payload,
            }
        },
    }


def main() -> int:
    load_dotenv()
    url, key_id, secret = api_client_from_env()
    owner = env("BALKANID_AGENT_OWNER_EMAIL")
    integration_id = env("INTEGRATION_ID")
    role_name = env_optional("SERVICE_ACCOUNT_ROLE_NAME") or env_optional("AGENT_NAME", "demo-support-agent")
    poll_s, timeout_s = poll_settings()

    if ci_mode():
        log_stderr(f"creating service account request owner={redact_identifier(owner)} role={role_name!r}")
    else:
        log_stderr(f"creating service account request owner={owner!r} role={role_name!r}")

    request_id = create_request(url, key_id, secret, create_input(owner, integration_id, role_name))
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
            label="CREATE_SERVICE_ACCOUNT",
        )
    except SystemExit as exc:
        code = exc.code if isinstance(exc.code, int) else 1
        print(json.dumps({"request_id": request_id, "status": "failed"}), file=sys.stderr)
        return code or 1

    aws_account_id = env_optional("AWS_ACCOUNT_ID")
    role_arn = env_optional("INTENDED_IAM_ROLE_ARN")
    if not role_arn and aws_account_id:
        role_arn = f"arn:aws:iam::{aws_account_id}:role{ROLE_PATH_PREFIX}{role_name}"

    out = {"request_id": request_id, "status": "approved", "role_name": role_name}
    if role_arn:
        out["expected_role_arn"] = role_arn
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
