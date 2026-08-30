#!/usr/bin/env python3
"""Trigger a BalkanID integration sync via Public API syncIntegration.

Run after Terraform creates AWS agent resources so the extractor discovers them.
Requires INTEGRATION_ID (or BALKANID_INTEGRATION_ID) and the same API key env as gate.py.
"""

from __future__ import annotations

import json
import os
import sys

# Reuse gate helpers (same repo, no extra deps).
from gate import env, gql, load_dotenv

SYNC = """
mutation SyncIntegration($input: SyncIntegrationInput!) {
  syncIntegration(input: $input) {
    success
    correlationId
  }
}
"""


def integration_id() -> str:
    for name in ("INTEGRATION_ID", "BALKANID_INTEGRATION_ID"):
        val = os.environ.get(name, "").strip()
        if val:
            return val
    raise SystemExit("missing INTEGRATION_ID (or BALKANID_INTEGRATION_ID) — required to trigger sync")


def main() -> int:
    load_dotenv()
    trigger = os.environ.get("TRIGGER_INTEGRATION_SYNC", "true").strip().lower()
    if trigger in ("0", "false", "no", "off"):
        print("TRIGGER_INTEGRATION_SYNC disabled; skipping sync", file=sys.stderr)
        return 0

    url = env("BALKANID_PUBLIC_API_URL")
    key_id = env("API_KEY_ID")
    secret = env("API_KEY_SECRET")
    iid = integration_id()

    print(f"triggering sync integration_id={iid!r}", file=sys.stderr)
    result = gql(url, key_id, secret, SYNC, {"input": {"integrationId": iid}})
    out = result.get("syncIntegration") or {}
    if not out.get("success"):
        raise SystemExit(f"syncIntegration failed: {out}")

    correlation_id = out.get("correlationId") or ""
    print(
        json.dumps(
            {
                "integration_id": iid,
                "correlation_id": correlation_id,
                "status": "accepted",
            }
        )
    )
    print(f"sync accepted correlation_id={correlation_id!r}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
