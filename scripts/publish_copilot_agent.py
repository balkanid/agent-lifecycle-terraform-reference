#!/usr/bin/env python3
"""Publish a Copilot Studio agent after its solution has been imported.

Terraform's `powerplatform_managed_solution` imports the solution that carries the
agent, but an imported agent is *not live* until it is published - and the provider
has no publish resource. `pac copilot publish` is the supported way to do it, so this
script wraps it and makes the step auditable in a pipeline.

Runs only after the BalkanID gates have passed; the caller is responsible for that
ordering (see scripts/copilot-local.sh and .github/workflows/copilot-cd.yml).

Requires the Power Platform CLI (`pac`) on PATH:
  dotnet tool install --global Microsoft.PowerApps.CLI.Tool
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys

from balkanid_api import env, env_optional, load_dotenv, log_stderr


def pac_binary() -> str:
    override = env_optional("PAC_CLI")
    candidate = override or "pac"
    resolved = shutil.which(candidate)
    if not resolved:
        raise SystemExit(
            f"Power Platform CLI not found ({candidate!r}). Install with:\n"
            "  dotnet tool install --global Microsoft.PowerApps.CLI.Tool\n"
            "or set PAC_CLI to its full path."
        )
    return resolved


def printable(args: list[str]) -> str:
    """Render a pac command for logs with the value after --clientSecret masked."""
    out: list[str] = []
    mask_next = False
    for arg in args:
        out.append("***" if mask_next else arg)
        mask_next = arg.lower() == "--clientsecret"
    return " ".join(out)


def run(pac: str, args: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
    shown = printable(args)
    log_stderr(f"$ pac {shown}")
    try:
        proc = subprocess.run([pac, *args], capture_output=True, text=True, timeout=900)
    except subprocess.TimeoutExpired:
        raise SystemExit(f"pac {shown} timed out after 900s")
    if proc.stdout.strip():
        log_stderr(proc.stdout.strip())
    if proc.returncode != 0:
        message = (proc.stderr or proc.stdout or "").strip()
        if check:
            raise SystemExit(f"pac {shown} failed: {message[:800]}")
        log_stderr(f"warning: pac {shown} failed: {message[:400]}")
    return proc


def authenticate(pac: str) -> None:
    """Create a service-principal auth profile if credentials are supplied.

    Skipped when PAC_USE_EXISTING_AUTH=true, so an interactive `pac auth create`
    profile on a workstation is reused.
    """
    if env_optional("PAC_USE_EXISTING_AUTH", "false").lower() in ("1", "true", "yes"):
        log_stderr("PAC_USE_EXISTING_AUTH set - using the current pac auth profile")
        return

    tenant = env_optional("AZURE_TENANT_ID")
    client_id = env_optional("AZURE_CLIENT_ID")
    client_secret = env_optional("AZURE_CLIENT_SECRET")
    environment_url = env_optional("DATAVERSE_ORG_URL")

    if not (tenant and client_id and client_secret):
        log_stderr("no service principal credentials in env - using the current pac auth profile")
        return

    # pac only accepts the secret as a flag. It is masked in every log line above, but it
    # is briefly visible in the process list - prefer PAC_USE_EXISTING_AUTH on shared hosts.
    args = [
        "auth",
        "create",
        "--name",
        env_optional("PAC_AUTH_PROFILE", "balkanid-agent-lifecycle"),
        "--tenant",
        tenant,
        "--applicationId",
        client_id,
        "--clientSecret",
        client_secret,
    ]
    if environment_url:
        args += ["--environment", environment_url]
    run(pac, args)


def main() -> int:
    load_dotenv()
    pac = pac_binary()

    bot = env_optional("AGENT_SCHEMA_NAME") or env_optional("AGENT_BOT_ID")
    if not bot:
        raise SystemExit(
            "set AGENT_SCHEMA_NAME (preferred, stable across environments) or AGENT_BOT_ID"
        )
    environment_id = env("POWER_PLATFORM_ENVIRONMENT_ID")

    authenticate(pac)

    run(pac, ["copilot", "publish", "--bot", bot, "--environment", environment_id])

    # `pac copilot status` takes the bot GUID; `publish` accepts either. Only run it
    # when a GUID was supplied, so a successful publish is not followed by a spurious
    # CLI error.
    status_output = ""
    bot_id = env_optional("AGENT_BOT_ID")
    if bot_id:
        status = run(
            pac,
            ["copilot", "status", "--bot-id", bot_id, "--environment", environment_id],
            check=False,
        )
        status_output = (status.stdout or "").strip()[:2000]
    else:
        log_stderr("AGENT_BOT_ID not set - skipping `pac copilot status` (it requires the bot GUID)")

    print(
        json.dumps(
            {
                "bot": bot,
                "environment_id": environment_id,
                "published": True,
                "status_output": status_output,
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
