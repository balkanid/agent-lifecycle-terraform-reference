#!/usr/bin/env python3
"""Create a BalkanID service account request for the agent's Entra identity, then wait.

Uses Public API createRequest (requestType: CREATE_SERVICE_ACCOUNT). Exit 0 only on
approval. Terraform (or your pipeline) creates the Entra object after approval - this
gate does not wait on BalkanID provisioning.

This is the Microsoft counterpart to the AWS reference's IAM-role gate. Every Copilot
agent eventually runs as *something* in Entra:

  * Copilot Studio agents created from May 2026 are issued an Entra Agent ID
    automatically; older agents carry a classic app registration.
  * Agent Builder agents use neither - set ENTRA_IDENTITY_GATE=false for those.

Reviewing the identity *before* it exists is what stops an agent from quietly
acquiring Graph permissions nobody approved.

Requires env vars from env.example. No third-party packages.

Exit codes:
  0  approved
  1  denied, or partially approved
  2  the approval window elapsed with no decision
  3  the policy service could not be reached
"""

from __future__ import annotations

import json
import sys

from balkanid_api import (
    ApprovalTimeout,
    TransportError,
    api_client_from_env,
    ci_mode,
    create_request,
    env,
    env_optional,
    load_dotenv,
    log_stderr,
    poll_request,
    poll_settings,
    record_approved_scope,
    redact_identifier,
)


def gate_reason() -> str:
    base = env_optional(
        "ENTRA_IDENTITY_PURPOSE",
        env_optional("AGENT_PURPOSE", "Entra identity for a Microsoft Copilot agent"),
    )
    name = identity_name()
    return f"{base} - create Entra identity for {name}"


def identity_name() -> str:
    return env_optional("ENTRA_IDENTITY_DISPLAY_NAME") or env_optional(
        "AGENT_NAME", "example-trial-intake-agent"
    )


def duration_input() -> dict:
    out: dict = {}
    duration_raw = env_optional("ENTRA_IDENTITY_DURATION_SECONDS") or env_optional(
        "LIFECYCLE_DURATION_SECONDS"
    )
    if duration_raw:
        out["duration"] = int(duration_raw)
    expiration = env_optional("ENTRA_IDENTITY_EXPIRATION_DATE") or env_optional(
        "LIFECYCLE_EXPIRATION_DATE"
    )
    if expiration:
        out["expirationDate"] = expiration
    return out


def graph_permissions() -> list[str]:
    """Graph application permissions the agent is asking for, as a reviewable list."""
    raw = env_optional("ENTRA_GRAPH_PERMISSIONS")
    return [item.strip() for item in raw.split(",") if item.strip()]


def role_grants() -> list[dict]:
    """Directory roles or entitlements attached to the create request."""
    role_name = env_optional("ENTRA_IDENTITY_ROLE_NAME") or env_optional("LIFECYCLE_POLICY_NAME")
    if not role_name:
        return []
    grant: dict = {"type": "role", "source_name": role_name}
    role_id = env_optional("ENTRA_IDENTITY_ROLE_ID") or env_optional("LIFECYCLE_POLICY_ID")
    if role_id:
        grant["source_id"] = role_id
    return [grant]


def create_input(owner: str, integration_id: str, name: str) -> dict:
    scim_payload: dict = {
        "entra_display_name": name,
        "description": env_optional(
            "ENTRA_IDENTITY_DESCRIPTION",
            "Copilot agent identity (created by Terraform after approval)",
        ),
        "sign_in_audience": env_optional("ENTRA_SIGN_IN_AUDIENCE", "AzureADMyOrg"),
    }

    permissions = graph_permissions()
    if permissions:
        scim_payload["graph_application_permissions"] = permissions

    environment_id = env_optional("POWER_PLATFORM_ENVIRONMENT_ID")
    if environment_id:
        scim_payload["power_platform_environment_id"] = environment_id

    grants = role_grants()
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
                "sourceType": env_optional("ENTRA_SOURCE_TYPE", "entra service principal"),
                "name": name,
                "scimPayload": scim_payload,
            }
        },
    }


def main() -> int:
    load_dotenv()
    url, key_id, secret = api_client_from_env()
    owner = env("BALKANID_AGENT_OWNER_EMAIL")
    integration_id = env("INTEGRATION_ID")
    name = identity_name()
    poll_s, timeout_s = poll_settings()

    if ci_mode():
        log_stderr(
            f"creating Entra identity request owner={redact_identifier(owner)} name={name!r}"
        )
    else:
        log_stderr(f"creating Entra identity request owner={owner!r} name={name!r}")

    permissions = graph_permissions()
    if permissions:
        log_stderr(f"requested Graph application permissions: {', '.join(permissions)}")

    # create_request is inside the try as well: a network failure here must report as
    # unreachable, not as a denial.
    request_id = ""
    try:
        request_id = create_request(url, key_id, secret, create_input(owner, integration_id, name))
        log_stderr(f"request_id={request_id}")
        log_stderr("waiting for approval (fail closed on deny/timeout)")

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
    except ApprovalTimeout as exc:
        log_stderr(exc.message)
        print(json.dumps({"request_id": request_id, "status": "timeout"}), file=sys.stderr)
        return 2
    except TransportError as exc:
        log_stderr(exc.message)
        print(json.dumps({"request_id": request_id, "status": "unreachable"}), file=sys.stderr)
        return 3
    except SystemExit as exc:
        code = exc.code if isinstance(exc.code, int) else 1
        status = "denied" if code == 1 else "failed"
        print(json.dumps({"request_id": request_id, "status": status}), file=sys.stderr)
        return code or 1

    record_approved_scope(
        {
            "identity_request_id": request_id,
            "entra_display_name": name,
            "graph_application_permissions": sorted(permissions),
        }
    )

    out = {
        "request_id": request_id,
        "status": "approved",
        "entra_display_name": name,
    }
    if permissions:
        out["graph_application_permissions"] = permissions
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
