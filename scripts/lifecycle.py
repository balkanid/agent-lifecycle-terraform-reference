#!/usr/bin/env python3
"""EN-8896: JIT identity lifecycle — create service role, assign, gate agent, teardown.

Phases (apply):
  1. CREATE_SERVICE_ACCOUNT (aws service role for AgentCore)
  2. SERVICE_ACCOUNT_ASSIGNMENT (managed policy grants, optional duration)
  3. Patch IAM trust policy for AgentCore (AWS CLI)
  4. AGENT_ACCESS (existing agent gate)
  5. Emit EXECUTION_ROLE_ARN + IDENTITY_ID for Terraform harness-only apply

Phases (teardown):
  1. DELETE_SERVICE_ACCOUNT (after harness destroyed externally)

Environment: see env.example (LIFECYCLE_* vars). No third-party packages.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

from balkanid_api import (
    api_client_from_env,
    ci_mode,
    create_request,
    env,
    env_optional,
    find_identity_id,
    load_dotenv,
    log_stderr,
    poll_request,
    redact_identifier,
    role_arn_from_identity,
)

PHASE_CREATE = "create_service_account"
PHASE_ASSIGN = "assign_service_account"
PHASE_AGENT = "agent_access"
PHASE_DELETE = "delete_service_account"


def poll_settings() -> tuple[int, int]:
    poll_s = int(os.environ.get("POLL_SECONDS", "5"))
    timeout_s = int(os.environ.get("POLL_TIMEOUT_SECONDS", "900"))
    return poll_s, timeout_s


def lifecycle_reason(suffix: str) -> str:
    base = env_optional("LIFECYCLE_REASON", env_optional("AGENT_PURPOSE", "Agent JIT lifecycle via Terraform"))
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


def create_service_account_input(owner: str, integration_id: str, role_name: str) -> dict:
    inp: dict = {
        "requestType": "CREATE_SERVICE_ACCOUNT",
        "employeeEmail": owner,
        "reason": lifecycle_reason("create service role"),
        **duration_input(),
        "payload": {
            "entity": {
                **entity_base(integration_id),
                "name": role_name,
                "scimPayload": {
                    "aws_service_role_name": role_name,
                    "aws_service_names": env_optional(
                        "LIFECYCLE_AWS_SERVICE_NAMES",
                        "bedrock-agentcore.amazonaws.com",
                    ),
                    "description": env_optional(
                        "LIFECYCLE_ROLE_DESCRIPTION",
                        "AgentCore execution role (JIT, BalkanID-governed)",
                    ),
                },
            }
        },
    }
    return inp


def assign_service_account_input(integration_id: str, identity_id: str) -> dict:
    policy_name = env("LIFECYCLE_POLICY_NAME")
    grants = [{"type": "policy", "source_name": policy_name}]
    policy_id = env_optional("LIFECYCLE_POLICY_ID")
    if policy_id:
        grants = [{"type": "policy", "source_id": policy_id, "source_name": policy_name}]

    inp: dict = {
        "requestType": "SERVICE_ACCOUNT_ASSIGNMENT",
        "reason": lifecycle_reason("assign entitlements"),
        **duration_input(),
        "payload": {
            "entity": {
                **entity_base(integration_id),
                "entity": identity_id,
                "scimPayload": {
                    "grants": grants,
                    "revokes": [],
                },
            }
        },
    }
    return inp


def revoke_service_account_input(integration_id: str, identity_id: str) -> dict:
    policy_name = env("LIFECYCLE_POLICY_NAME")
    revokes = [{"type": "policy", "source_name": policy_name}]
    policy_id = env_optional("LIFECYCLE_POLICY_ID")
    if policy_id:
        revokes = [{"type": "policy", "source_id": policy_id, "source_name": policy_name}]

    return {
        "requestType": "SERVICE_ACCOUNT_ASSIGNMENT",
        "reason": lifecycle_reason("revoke entitlements"),
        "payload": {
            "entity": {
                **entity_base(integration_id),
                "entity": identity_id,
                "scimPayload": {
                    "grants": [],
                    "revokes": revokes,
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


def delete_service_account_input(integration_id: str, identity_id: str, role_name: str) -> dict:
    return {
        "requestType": "DELETE_SERVICE_ACCOUNT",
        "reason": lifecycle_reason("deprovision service role"),
        "payload": {
            "entity": {
                **entity_base(integration_id),
                "entity": identity_id,
                "name": role_name,
                "scimPayload": {},
            }
        },
    }


def agentcore_trust_policy(aws_account_id: str, aws_region: str) -> str:
    return json.dumps(
        {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Principal": {"Service": "bedrock-agentcore.amazonaws.com"},
                    "Action": "sts:AssumeRole",
                    "Condition": {
                        "StringEquals": {"aws:SourceAccount": aws_account_id},
                        "ArnLike": {
                            "aws:SourceArn": f"arn:aws:bedrock-agentcore:{aws_region}:{aws_account_id}:*"
                        },
                    },
                }
            ],
        }
    )


def patch_agentcore_trust(role_name: str, aws_account_id: str, aws_region: str) -> None:
    if env_optional("LIFECYCLE_SKIP_TRUST_PATCH", "false").lower() in ("1", "true", "yes"):
        log_stderr("skipping AgentCore trust policy patch (LIFECYCLE_SKIP_TRUST_PATCH=true)")
        return

    policy = agentcore_trust_policy(aws_account_id, aws_region)
    log_stderr(f"patching AgentCore trust policy on role={role_name!r}")
    proc = subprocess.run(
        [
            "aws",
            "iam",
            "update-assume-role-policy",
            "--role-name",
            role_name,
            "--policy-document",
            policy,
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise SystemExit(f"failed to patch trust policy on {role_name}: {detail}")
    log_stderr("AgentCore trust policy patched")


def write_outputs(path: str, payload: dict) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")
    log_stderr(f"wrote lifecycle outputs to {path}")


def load_state(path: str) -> dict:
    if not os.path.isfile(path):
        raise SystemExit(f"lifecycle state not found: {path} (run apply phase first)")
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def phase_apply(phase: str) -> int:
    load_dotenv()
    url, key_id, secret = api_client_from_env()
    owner = env("BALKANID_AGENT_OWNER_EMAIL")
    integration_id = env("INTEGRATION_ID")
    role_name = env_optional("LIFECYCLE_ROLE_NAME") or env_optional("AGENT_NAME", "demo-support-agent")
    agent_name = env_optional("AGENT_NAME", role_name)
    aws_account_id = env("AWS_ACCOUNT_ID")
    aws_region = env_optional("AWS_REGION", "us-east-1")
    poll_s, timeout_s = poll_settings()
    state_path = env_optional("LIFECYCLE_STATE_FILE", ".lifecycle_state.json")

    if ci_mode():
        log_stderr(f"lifecycle phase={phase} owner={redact_identifier(owner)} role={role_name!r}")
    else:
        log_stderr(f"lifecycle phase={phase} owner={owner!r} role={role_name!r}")

    state: dict = {}
    if os.path.isfile(state_path):
        with open(state_path, encoding="utf-8") as fh:
            state = json.load(fh)

    if phase in (PHASE_CREATE, "apply-all"):
        req_id = create_request(url, key_id, secret, create_service_account_input(owner, integration_id, role_name))
        poll_request(
            url,
            key_id,
            secret,
            req_id,
            wait_provisioning=True,
            poll_s=poll_s,
            timeout_s=timeout_s,
            label="CREATE_SERVICE_ACCOUNT",
        )
        identity = find_identity_id(
            url,
            key_id,
            secret,
            integration_id,
            role_name,
            poll_s=poll_s,
            timeout_s=min(timeout_s, 600),
        )
        role_arn = role_arn_from_identity(role_name, identity, aws_account_id)
        state.update(
            {
                "create_request_id": req_id,
                "identity_id": identity["id"],
                "role_name": role_name,
                "role_arn": role_arn,
            }
        )
        patch_agentcore_trust(role_name, aws_account_id, aws_region)
        write_outputs(state_path, state)
        if phase == PHASE_CREATE:
            print(json.dumps(state))
            return 0

    identity_id = state.get("identity_id") or env_optional("LIFECYCLE_IDENTITY_ID")
    role_arn = state.get("role_arn") or env_optional("EXECUTION_ROLE_ARN")
    if not identity_id:
        identity = find_identity_id(url, key_id, secret, integration_id, role_name, poll_s=poll_s, timeout_s=120)
        identity_id = identity["id"]
        role_arn = role_arn_from_identity(role_name, identity, aws_account_id)
        state["identity_id"] = identity_id
        state["role_arn"] = role_arn

    if phase in (PHASE_ASSIGN, "apply-all"):
        req_id = create_request(
            url,
            key_id,
            secret,
            assign_service_account_input(integration_id, identity_id),
        )
        poll_request(
            url,
            key_id,
            secret,
            req_id,
            wait_provisioning=True,
            poll_s=poll_s,
            timeout_s=timeout_s,
            label="SERVICE_ACCOUNT_ASSIGNMENT",
        )
        state["assign_request_id"] = req_id
        write_outputs(state_path, state)
        if phase == PHASE_ASSIGN:
            print(json.dumps(state))
            return 0

    if phase in (PHASE_AGENT, "apply-all"):
        if not role_arn:
            role_arn = role_arn_from_identity(role_name, {"sourceId": ""}, aws_account_id)
        req_id = create_request(
            url,
            key_id,
            secret,
            agent_access_input(owner, integration_id, agent_name, role_arn),
        )
        poll_request(
            url,
            key_id,
            secret,
            req_id,
            wait_provisioning=False,
            poll_s=poll_s,
            timeout_s=timeout_s,
            label="AGENT_ACCESS",
        )
        state["agent_request_id"] = req_id
        state["execution_role_arn"] = role_arn
        write_outputs(state_path, state)
        print(json.dumps(state))
        return 0

    raise SystemExit(f"unknown apply phase: {phase}")


def phase_teardown(mode: str) -> int:
    load_dotenv()
    url, key_id, secret = api_client_from_env()
    integration_id = env("INTEGRATION_ID")
    poll_s, timeout_s = poll_settings()
    state_path = env_optional("LIFECYCLE_STATE_FILE", ".lifecycle_state.json")
    state = load_state(state_path)

    identity_id = state.get("identity_id") or env("LIFECYCLE_IDENTITY_ID")
    role_name = state.get("role_name") or env_optional("LIFECYCLE_ROLE_NAME") or env_optional("AGENT_NAME")

    if mode == "revoke-only":
        req_id = create_request(
            url,
            key_id,
            secret,
            revoke_service_account_input(integration_id, identity_id),
        )
        poll_request(
            url,
            key_id,
            secret,
            req_id,
            wait_provisioning=True,
            poll_s=poll_s,
            timeout_s=timeout_s,
            label="SERVICE_ACCOUNT_ASSIGNMENT(revoke)",
        )
        print(json.dumps({"revoke_request_id": req_id}))
        return 0

    req_id = create_request(
        url,
        key_id,
        secret,
        delete_service_account_input(integration_id, identity_id, role_name),
    )
    poll_request(
        url,
        key_id,
        secret,
        req_id,
        wait_provisioning=True,
        poll_s=poll_s,
        timeout_s=timeout_s,
        label="DELETE_SERVICE_ACCOUNT",
    )
    if os.path.isfile(state_path):
        os.remove(state_path)
    print(json.dumps({"delete_request_id": req_id, "status": "deleted"}))
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        raise SystemExit(
            "usage: lifecycle.py {apply-all|create-service-account|assign|agent-access|"
            "delete-identity|revoke-assignment}"
        )
    cmd = sys.argv[1].strip().lower()
    mapping = {
        "apply-all": "apply-all",
        "create-service-account": PHASE_CREATE,
        "assign": PHASE_ASSIGN,
        "agent-access": PHASE_AGENT,
        "delete-identity": "delete",
        "revoke-assignment": "revoke-only",
    }
    if cmd not in mapping:
        raise SystemExit(f"unknown command: {cmd}")
    target = mapping[cmd]
    if target in (PHASE_CREATE, PHASE_ASSIGN, PHASE_AGENT, "apply-all"):
        return phase_apply(target)
    return phase_teardown(target)


if __name__ == "__main__":
    sys.exit(main())
