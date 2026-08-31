#!/usr/bin/env python3
"""Import all gate scripts to catch broken cross-module imports (py_compile misses these)."""

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
)


def main() -> int:
    scripts = Path(__file__).resolve().parent
    sys.path.insert(0, str(scripts))
    for name in MODULES:
        importlib.import_module(name)
    print(f"imported {len(MODULES)} modules ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
