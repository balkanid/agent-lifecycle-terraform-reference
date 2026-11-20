#!/usr/bin/env python3
"""Import every script module to catch broken cross-module imports (py_compile misses these)."""

from __future__ import annotations

import importlib
import sys
from pathlib import Path

MODULES = (
    "balkanid_api",
    "gate",
    "service_account_gate",
    "trigger_sync",
    "preflight",
    "policy_check",
    "request_sensitive_access",
    "reap_expired",
    "entra_agent_identity_gate",
    "publish_copilot_agent",
    "verify_approved_scope",
)


def main() -> int:
    scripts = Path(__file__).resolve().parent
    sys.path.insert(0, str(scripts))
    for name in MODULES:
        module = importlib.import_module(name)
        if name != "balkanid_api" and not callable(getattr(module, "main", None)):
            raise SystemExit(f"{name}: no callable main()")
    print(f"imported {len(MODULES)} modules ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
