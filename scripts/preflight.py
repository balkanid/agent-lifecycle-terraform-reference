#!/usr/bin/env python3
"""Validate CD/local env before gates, Terraform, publish or sync run.

LIFECYCLE_TARGET picks the checks: bedrock (default, the CI gate), bedrock-guardrails
(scripts/lifecycle.sh) or copilot (Copilot Studio). Exit 1 with ::error:: lines on any problem.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys

from balkanid_api import env_optional, lifecycle_target, load_dotenv, log_stderr


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


def check_bedrock(operation: str, errors: list[str], warnings: list[str]) -> None:
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


def check_bedrock_guardrails(operation: str, errors: list[str], warnings: list[str]) -> None:
    names = ["BALKANID_PUBLIC_API_URL", "API_KEY_ID", "API_KEY_SECRET", "INTEGRATION_ID", "AWS_ACCOUNT_ID"]
    if operation == "apply":
        names.append("BALKANID_AGENT_OWNER_EMAIL")
    for name in names:
        require(name, errors)
    for tool in ("terraform", "aws"):
        if not shutil.which(tool):
            warnings.append(f"{tool} not found on PATH")
    if env_optional("EXISTING_EXECUTION_ROLE_ARN"):
        warnings.append("EXISTING_EXECUTION_ROLE_ARN is set; policy_check.py will refuse it")
    try:
        from policy_check import load_guardrails

        load_guardrails()
    except Exception as exc:  # noqa: BLE001
        errors.append(f"policies/guardrails.json invalid: {exc}")


def check_copilot(operation: str, errors: list[str], warnings: list[str]) -> None:
    identity_gate = is_true("ENTRA_IDENTITY_GATE")
    agent_gate = is_true("AGENT_GATE", "true")
    provision = is_true("PROVISION_COPILOT_AGENT")
    publish = is_true("PUBLISH_AGENT")
    sync = is_true("TRIGGER_INTEGRATION_SYNC", "true")

    if operation == "apply":
        if not identity_gate and not agent_gate:
            warnings.append("both ENTRA_IDENTITY_GATE and AGENT_GATE are false — no BalkanID approvals will run")
        if identity_gate or agent_gate:
            for name in ("BALKANID_PUBLIC_API_URL", "API_KEY_ID", "API_KEY_SECRET", "BALKANID_AGENT_OWNER_EMAIL", "INTEGRATION_ID"):
                require(name, errors)
            if identity_gate and not env_optional("ENTRA_GRAPH_PERMISSIONS"):
                warnings.append(
                    "ENTRA_GRAPH_PERMISSIONS not set — the identity request will omit the permission list "
                    "the approver is meant to review"
                )
        if provision or publish:
            for name in ("AZURE_TENANT_ID", "AZURE_CLIENT_ID", "AZURE_CLIENT_SECRET", "POWER_PLATFORM_ENVIRONMENT_ID"):
                require(name, errors)
            path = env_optional("SOLUTION_ZIP_PATH")
            if not path:
                warnings.append("SOLUTION_ZIP_PATH not set — Terraform will not import a solution")
            elif not os.path.isfile(path):
                errors.append(f"SOLUTION_ZIP_PATH does not exist: {path}")
            if publish:
                # copilot-cd.yml installs pac in a later step, so only check it outside Actions.
                if os.environ.get("GITHUB_ACTIONS") != "true" and not shutil.which(env_optional("PAC_CLI") or "pac"):
                    errors.append(
                        "Power Platform CLI (pac) not on PATH — required to publish a Copilot Studio agent. "
                        "Install: dotnet tool install --global Microsoft.PowerApps.CLI.Tool"
                    )
                if not (env_optional("AGENT_SCHEMA_NAME") or env_optional("AGENT_BOT_ID")):
                    errors.append("publishing a Copilot Studio agent needs AGENT_SCHEMA_NAME or AGENT_BOT_ID")
        if sync:
            require("INTEGRATION_ID", errors)

    if operation == "destroy" and provision:
        for name in ("AZURE_TENANT_ID", "AZURE_CLIENT_ID", "AZURE_CLIENT_SECRET"):
            require(name, errors)


CHECKS = {"bedrock": check_bedrock, "bedrock-guardrails": check_bedrock_guardrails, "copilot": check_copilot}


def main() -> int:
    load_dotenv()
    operation = env_optional("CD_OPERATION", "apply").lower()
    errors: list[str] = []
    warnings: list[str] = []
    try:
        target = lifecycle_target()
    except SystemExit as exc:
        errors.append(str(exc))
    else:
        CHECKS[target](operation, errors, warnings)

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
