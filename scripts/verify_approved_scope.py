#!/usr/bin/env python3
"""Fail if the environment about to provision differs from what was approved.

The gates and the provisioning steps read their configuration from the same environment
independently. Nothing otherwise stops a variable changing between the two, which would
consent permissions or import a solution that no approver saw, while the approval record
asserts the opposite. That gap matters most in exactly the setting where this pattern is
adopted: an approval record is only evidence if it describes what was actually created.

Run after the gates and before any provisioning. Reads the file the gates wrote
(APPROVED_SCOPE_FILE, default .approved-scope.json).

Exit codes:
  0  the environment matches what was approved
  1  drift detected, nothing should be provisioned
  2  no approval record found
"""

from __future__ import annotations

import json
import os
import sys

from balkanid_api import env_optional, load_dotenv, log_stderr


def requested_permissions() -> list[str]:
    raw = env_optional("ENTRA_GRAPH_PERMISSIONS")
    return sorted({item.strip() for item in raw.split(",") if item.strip()})


def compare(approved: dict) -> list[str]:
    """Return a list of human-readable drift descriptions. Empty means no drift."""
    drift: list[str] = []

    # Each gate records a fixed set of fields alongside its request id. A field missing
    # from a gate that did run means the record is incomplete, so fail closed rather
    # than skip the comparison. Fields belonging to a gate that did not run are skipped.
    required: set[str] = set()
    if approved.get("agent_request_id"):
        required |= {"agent_name", "copilot_surface", "environment_id", "solution_unique_name"}
    if approved.get("identity_request_id"):
        required |= {"entra_display_name", "graph_application_permissions"}

    def check(field: str, approved_value, current_value, label: str) -> None:
        if field not in approved:
            if field in required:
                drift.append(f"{label}: missing from the approval record")
            return
        if (approved_value or "") != (current_value or ""):
            drift.append(
                f"{label}: approved {approved_value!r}, about to provision {current_value!r}"
            )

    check("agent_name", approved.get("agent_name"), env_optional("AGENT_NAME"), "agent name")
    # Only Copilot Studio is supported. A record naming anything else is not ours.
    check("copilot_surface", approved.get("copilot_surface"), "copilot-studio", "Copilot surface")
    check(
        "environment_id",
        approved.get("environment_id"),
        env_optional("POWER_PLATFORM_ENVIRONMENT_ID"),
        "Power Platform environment",
    )
    check(
        "solution_unique_name",
        approved.get("solution_unique_name"),
        env_optional("SOLUTION_UNIQUE_NAME"),
        "solution",
    )
    check(
        "entra_display_name",
        approved.get("entra_display_name"),
        env_optional("ENTRA_IDENTITY_DISPLAY_NAME") or env_optional("AGENT_NAME"),
        "Entra identity name",
    )

    if "graph_application_permissions" not in approved and requested_permissions():
        # Permissions are requested but the identity gate never recorded an approval for
        # them (for example ENTRA_IDENTITY_GATE=false). Fail closed.
        drift.append(
            "Graph permissions not approved: " + ", ".join(requested_permissions())
        )

    if "graph_application_permissions" in approved:
        was = sorted(approved.get("graph_application_permissions") or [])
        now = requested_permissions()
        added = sorted(set(now) - set(was))
        removed = sorted(set(was) - set(now))
        if added:
            drift.append(
                "Graph permissions not approved: " + ", ".join(added)
            )
        if removed:
            # Narrowing is safe to proceed with, but say so: the approval record will
            # describe a wider scope than what was granted.
            log_stderr(
                "note: these approved permissions are no longer requested and will not be "
                "granted: " + ", ".join(removed)
            )

    return drift


def main() -> int:
    load_dotenv()

    path = env_optional("APPROVED_SCOPE_FILE", ".approved-scope.json")
    if not os.path.isfile(path):
        log_stderr(
            f"no approval record at {path}. Run the gates first, or set "
            "VERIFY_APPROVED_SCOPE=false if you are deliberately provisioning without one."
        )
        return 2

    try:
        with open(path, encoding="utf-8") as fh:
            approved = json.load(fh)
    except (json.JSONDecodeError, OSError) as exc:
        log_stderr(f"could not read {path}: {exc}")
        return 2

    if not isinstance(approved, dict) or not (
        approved.get("agent_request_id") or approved.get("identity_request_id")
    ):
        log_stderr(f"{path} does not reference an approved request. Run the gates first.")
        return 2

    drift = compare(approved)
    if drift:
        log_stderr("the environment does not match what was approved:")
        for item in drift:
            log_stderr(f"  {item}")
        log_stderr("")
        log_stderr("refusing to provision. Re-run the gates for the current configuration.")
        print(json.dumps({"status": "drift", "differences": drift}), file=sys.stderr)
        return 1

    log_stderr("environment matches the approved scope")
    print(json.dumps({"status": "verified", **{k: approved[k] for k in sorted(approved)}}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
