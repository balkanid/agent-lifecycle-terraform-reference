#!/usr/bin/env python3
"""Validate CD/local env before gates, Terraform, or sync run."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys

from balkanid_api import env_optional, load_dotenv, log_stderr


def is_true(name: str, default: str = "false") -> bool:
    return env_optional(name, default).lower() in ("1", "true", "yes")


def require(name: str, errors: list[str]) -> None:
    if not env_optional(name):
        errors.append(f"missing {name}")


def _check_aws_iam_policy(warnings: list[str], errors: list[str]) -> None:
    if not shutil.which("aws"):
        warnings.append("aws CLI not available — skipping IAM policy smoke test")
        return
    region = env_optional("AWS_REGION", "us-east-1")
    agent_name = env_optional("AGENT_NAME", "demo-support-agent")
    env = {
        **os.environ,
        "AWS_DEFAULT_REGION": region,
    }
    for key in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"):
        val = env_optional(key)
        if val:
            env[key] = val
    try:
        proc = subprocess.run(
            [
                "aws",
                "iam",
                "list-roles",
                "--query",
                f"Roles[?RoleName=='{agent_name}'] | length(@)",
                "--output",
                "text",
            ],
            capture_output=True,
            text=True,
            timeout=30,
            env=env,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        warnings.append(f"IAM policy smoke test skipped: {exc}")
        return
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        if "AccessDenied" in err or "not authorized" in err:
            errors.append(
                "bedrock-lifecycle.user lacks iam:ListRoles — replace the attached policy with "
                "aws/bedrock-agent-lifecycle-iam-policy.json (full replace, not merge)"
            )
        else:
            warnings.append(f"IAM policy smoke test failed: {err}")
        return
    log_stderr("preflight: iam:ListRoles ok")


def main() -> int:
    load_dotenv()
    operation = env_optional("CD_OPERATION", "apply").lower()
    errors: list[str] = []
    warnings: list[str] = []

    service_gate = is_true("SERVICE_ACCOUNT_GATE")
    agent_gate = is_true("AGENT_GATE", "true")
    provision = is_true("PROVISION_AWS_AGENT")
    sync = is_true("TRIGGER_INTEGRATION_SYNC", "true")

    if operation == "apply":
        if not service_gate and not agent_gate:
            warnings.append("both SERVICE_ACCOUNT_GATE and AGENT_GATE are false — no BalkanID approvals will run")
        if service_gate or agent_gate:
            require("BALKANID_PUBLIC_API_URL", errors)
            require("API_KEY_ID", errors)
            require("API_KEY_SECRET", errors)
            require("BALKANID_AGENT_OWNER_EMAIL", errors)
            require("INTEGRATION_ID", errors)
            if service_gate and not (env_optional("SERVICE_ACCOUNT_POLICY_NAME") or env_optional("LIFECYCLE_POLICY_NAME")):
                warnings.append("SERVICE_ACCOUNT_POLICY_NAME not set — create request will omit policy grants")
        if provision:
            require("AWS_ACCESS_KEY_ID", errors)
            require("AWS_SECRET_ACCESS_KEY", errors)
            _check_aws_iam_policy(warnings, errors)
        if sync and provision:
            require("INTEGRATION_ID", errors)

    if operation == "destroy" and provision:
        require("AWS_ACCESS_KEY_ID", errors)
        require("AWS_SECRET_ACCESS_KEY", errors)

    poll_s = env_optional("POLL_SECONDS", "5")
    if not poll_s.isdigit() or int(poll_s) < 1:
        errors.append(f"invalid POLL_SECONDS={poll_s!r} (must be a positive integer)")

    for msg in warnings:
        log_stderr(f"warning: {msg}")
        print(f"::warning::{msg}", file=sys.stderr)

    if errors:
        for msg in errors:
            log_stderr(f"error: {msg}")
            print(f"::error::{msg}", file=sys.stderr)
        return 1

    log_stderr("preflight ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
