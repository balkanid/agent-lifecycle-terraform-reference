#!/usr/bin/env python3
"""Create a BalkanID agent access request and wait until approved or denied.

Uses Public API createRequest (requestType: AGENT_ACCESS). Exit 0 only on approval.
Requires env vars from env.example. No third-party packages.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

CREATE = """
mutation CreateAgentAccessRequest($input: CreateRequestInput!) {
  createRequest(input: $input) {
    id
    success
    eventIds
    stepUpRequired
  }
}
"""

GET = """
query RequestStatus($filter: RequestFilterInput, $first: Int) {
  requests(filter: $filter, first: $first) {
    edges {
      node {
        id
        status
        requestApprovalStatus
        requestProvisioningStatus
        requestType
      }
    }
  }
}
"""

APPROVED = {
    "approved",
    "completed",
    "provisioned",
    "partially_approved",
    "partially approved",
}
DENIED = {
    "denied",
    "rejected",
    "cancelled",
    "canceled",
    "failed",
}

USER_AGENT = (
    "balkanid-agent-lifecycle-pov/1.0 "
    "(+https://github.com/balkanid/agent-lifecycle-terraform-pov)"
)


def load_dotenv() -> None:
    """Load repo-root .env when vars are not already exported (local dev convenience)."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(root, ".env")
    if not os.path.isfile(path):
        return
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            if key:
                os.environ[key] = value


def http_error_message(code: int, detail: str, url: str = "") -> str:
    lower = detail.lower()
    if code == 403 and any(token in lower for token in ("cloudflare", "cf-ray", "blocked")):
        ray = ""
        match = re.search(r"Ray ID[^<]*<strong[^>]*>([^<]+)</strong>", detail, re.I)
        if match:
            ray = f" (Ray ID: {match.group(1).strip()})"
        return (
            f"HTTP 403: Cloudflare blocked this request{ray}. "
            "GitHub-hosted runners are often blocked by WAF — allowlist GitHub Actions "
            "IP ranges on your tenant domain or add a WAF skip rule for /api/public "
            "when X-Api-Key-Id is present. See .github/CD_CONFIG.md."
        )
    if "<html" in lower:
        return (
            f"HTTP {code}: non-JSON response from public API "
            "(body looks like HTML; check URL and edge/WAF rules)"
        )
    if code == 404:
        hint = (
            " Public API is served on the platform host (e.g. https://balkanid.dev/api/public), "
            "not tenant subdomains like https://qa.balkanid.dev. "
            "If .env is correct, your shell may still export a stale BALKANID_PUBLIC_API_URL — "
            "run `echo $BALKANID_PUBLIC_API_URL` or rely on gate.py loading .env automatically."
        )
        return f"HTTP 404 from public API: {detail.strip()}.{hint}"
    if len(detail) > 800:
        detail = detail[:800] + "..."
    return f"HTTP {code} from public API: {detail}"


def env(name: str, default: str | None = None) -> str:
    val = os.environ.get(name, default)
    if val is None or val.strip() == "":
        raise SystemExit(f"missing required env {name}")
    return val.strip()


def gql(url: str, key_id: str, secret: str, query: str, variables: dict) -> dict:
    body = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
            "X-Api-Key-Id": key_id,
            "X-Api-Key-Secret": secret,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = json.loads(resp.read().decode())
    except urllib.error.HTTPError as err:
        detail = err.read().decode() if err.fp else ""
        raise SystemExit(http_error_message(err.code, detail, url)) from err
    if payload.get("errors"):
        raise SystemExit(json.dumps(payload["errors"], indent=2))
    data = payload.get("data")
    if not data:
        raise SystemExit(f"empty GraphQL data: {payload}")
    return data


def terminal(status: str | None, approval: str | None) -> str | None:
    for raw in (status, approval):
        if not raw:
            continue
        n = raw.strip().lower().replace("-", "_").replace(" ", "_")
        if n in APPROVED or "approv" in n and "pending" not in n and "await" not in n:
            if n in DENIED:
                return "denied"
            if n in APPROVED or n.endswith("approved"):
                return "approved"
        if n in DENIED or "denied" in n or "reject" in n:
            return "denied"
    return None


def main() -> int:
    load_dotenv()
    url = env("BALKANID_PUBLIC_API_URL")
    key_id = env("API_KEY_ID")
    secret = env("API_KEY_SECRET")
    owner = env("BALKANID_AGENT_OWNER_EMAIL")
    agent = os.environ.get("AGENT_NAME", "demo-support-agent").strip()
    agent_type = os.environ.get("AGENT_TYPE", "terraform").strip()
    integration = os.environ.get("INTEGRATION_ID", "").strip()
    purpose = os.environ.get("AGENT_PURPOSE", "Demo agent lifecycle PoV").strip()
    role_arn = os.environ.get("INTENDED_IAM_ROLE_ARN", "").strip()
    poll_s = int(os.environ.get("POLL_SECONDS", "5"))
    timeout_s = int(os.environ.get("POLL_TIMEOUT_SECONDS", "900"))

    reason = purpose
    if not reason:
        reason = f"Terraform gate for agent {agent}"

    print(f"public API url={url}", file=sys.stderr)
    print(f"creating agent access request owner={owner!r} agent={agent!r}", file=sys.stderr)

    agent_access: dict = {
        "action": "CREATE",
        "name": agent,
        "agentType": agent_type,
    }
    if integration:
        agent_access["integrationId"] = integration
    if role_arn:
        agent_access["intendedIamRoleArn"] = role_arn

    inp: dict = {
        "requestType": "AGENT_ACCESS",
        "employeeEmail": owner,
        "reason": reason,
        "runAsync": False,
        "payload": {"agentAccess": agent_access},
    }

    created = gql(url, key_id, secret, CREATE, {"input": inp})["createRequest"]

    if created.get("stepUpRequired"):
        raise SystemExit("step-up MFA required on createRequest; complete MFA and retry")
    if not created.get("success") or not created.get("id"):
        raise SystemExit(f"createRequest failed: {created}")

    request_id = created["id"]
    print(f"request_id={request_id}", file=sys.stderr)
    print("waiting for approval in BalkanID (fail closed on deny/timeout)", file=sys.stderr)

    deadline = time.time() + timeout_s
    while time.time() < deadline:
        listed = gql(
            url,
            key_id,
            secret,
            GET,
            {"filter": {"id": {"_eq": request_id}}, "first": 1},
        )
        edges = (listed.get("requests") or {}).get("edges") or []
        node = (edges[0] or {}).get("node") if edges else None
        if node:
            status = node.get("status")
            approval = node.get("requestApprovalStatus")
            req_type = node.get("requestType")
            print(
                f"status={status!r} approval={approval!r} requestType={req_type!r}",
                file=sys.stderr,
            )
            outcome = terminal(status, approval)
            if outcome == "approved":
                print(json.dumps({"request_id": request_id, "status": "approved"}))
                return 0
            if outcome == "denied":
                print(json.dumps({"request_id": request_id, "status": "denied"}), file=sys.stderr)
                return 1
        time.sleep(poll_s)

    print(f"timed out after {timeout_s}s waiting on {request_id}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
