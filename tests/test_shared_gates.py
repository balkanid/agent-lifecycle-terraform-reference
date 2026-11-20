"""Tests for the shared gates' default (Bedrock CI) and Copilot targets and the shared API client.

Run: python3 -m unittest discover -s tests -v   (standard library only)
"""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import balkanid_api as api  # noqa: E402
import gate  # noqa: E402
import preflight  # noqa: E402
import service_account_gate  # noqa: E402
from mock_balkanid import MockBalkanID  # noqa: E402


def run(main):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = main()
    return code, out.getvalue(), err.getvalue()


class ApprovalOutcomeTests(unittest.TestCase):
    def test_outcomes(self):
        self.assertEqual(api.approval_outcome("approved", "approved"), "approved")
        self.assertEqual(api.approval_outcome("approved-provisioned", "approved"), "approved")
        self.assertEqual(api.approval_outcome("pending", "pending_approval"), None)
        self.assertEqual(api.approval_outcome("denied", "approved"), "denied")
        self.assertEqual(api.approval_outcome("partially-approved", "partially-approved"), "partial")
        self.assertEqual(api.approval_outcome("invalid", "invalid"), "denied")
        self.assertEqual(api.approval_outcome("consent_denied", ""), "denied")


class GateTests(unittest.TestCase):
    def setUp(self):
        self.mock = MockBalkanID().__enter__()
        self.addCleanup(self.mock.__exit__, None, None, None)
        self.tmp = tempfile.mkdtemp()
        env = {
            "BALKANID_SKIP_DOTENV": "1", "BALKANID_PUBLIC_API_URL": self.mock.url, "API_KEY_ID": "test-key",
            "API_KEY_SECRET": "s", "BALKANID_AGENT_OWNER_EMAIL": "owner@example.com", "INTEGRATION_ID": "int-aws",
            "AWS_ACCOUNT_ID": "123456789012", "AGENT_NAME": "demo-support-agent", "POLL_SECONDS": "1",
            "POLL_TIMEOUT_SECONDS": "2", "GQL_MAX_RETRIES": "1",
            "APPROVED_SCOPE_FILE": os.path.join(self.tmp, "scope.json"),
        }
        p = mock.patch.dict(os.environ, env)
        p.start()
        self.addCleanup(p.stop)
        for k in ("CI", "GITHUB_ACTIONS", "LIFECYCLE_TARGET", "INTENDED_IAM_ROLE_ARN", "SERVICE_ACCOUNT_ROLE_NAME",
                  "SERVICE_ACCOUNT_POLICY_NAME", "AGENT_TYPE", "AGENT_PURPOSE"):
            os.environ.pop(k, None)

    def test_bedrock_agent_gate_payload_is_unchanged(self):
        code, out, _ = run(gate.main)
        self.assertEqual(code, 0)
        sent = self.mock.created[0]
        self.assertEqual(sent["requestType"], "AGENT_ACCESS")
        self.assertEqual(sent["payload"]["agentAccess"], {
            "action": "CREATE", "name": "demo-support-agent", "agentType": "terraform", "integrationId": "int-aws",
            "intendedIamRoleArn": "arn:aws:iam::123456789012:role/balkanid-agent-lifecycle/demo-support-agent",
        })
        self.assertNotIn("expirationDate", sent)
        self.assertEqual(json.loads(out)["status"], "approved")

    def test_bedrock_service_account_gate_has_no_identity_type(self):
        os.environ["SERVICE_ACCOUNT_POLICY_NAME"] = "AmazonBedrockFullAccess"
        code, out, _ = run(service_account_gate.main)
        self.assertEqual(code, 0)
        entity = self.mock.created[0]["payload"]["entity"]
        self.assertNotIn("identityType", entity)
        self.assertEqual(entity["name"], "demo-support-agent")
        self.assertEqual(entity["sourceType"], "aws service role")
        self.assertEqual(entity["scimPayload"]["grants"], [{"type": "policy", "source_name": "AmazonBedrockFullAccess"}])
        self.assertEqual(json.loads(out)["expected_role_arn"],
                         "arn:aws:iam::123456789012:role/balkanid-agent-lifecycle/demo-support-agent")

    def test_partial_approval_fails_closed(self):
        self.mock.next_status = "partially-approved"
        code, out, _ = run(gate.main)
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(out)["status"], "denied")

    def test_timeout_exits_2(self):
        self.mock.next_status = "pending"
        code, out, _ = run(gate.main)
        self.assertEqual(code, 2)
        self.assertEqual(json.loads(out)["status"], "timeout")

    def test_unreachable_exits_3_and_never_prints_secret(self):
        os.environ["BALKANID_PUBLIC_API_URL"] = "http://127.0.0.1:9/api/public"
        os.environ["API_KEY_SECRET"] = "super-secret-value"
        code, out, err = run(gate.main)
        self.assertEqual(code, 3)
        self.assertNotIn("super-secret-value", out + err)

    def test_copilot_gate_puts_placement_in_metadata_and_records_scope(self):
        os.environ.update({"LIFECYCLE_TARGET": "copilot", "AGENT_NAME": "trial-intake",
                           "POWER_PLATFORM_ENVIRONMENT_ID": "env-1", "SOLUTION_UNIQUE_NAME": "Sol"})
        code, _, _ = run(gate.main)
        self.assertEqual(code, 0)
        aa = self.mock.created[0]["payload"]["agentAccess"]
        self.assertEqual(aa["agentType"], "copilot-studio")
        self.assertEqual(aa["metadata"]["environmentId"], "env-1")
        allowed = {"action", "name", "agentType", "integrationId", "description", "intendedIamRoleArn", "metadata"}
        self.assertLessEqual(set(aa), allowed)  # only AgentAccessPayloadInput fields
        with open(os.environ["APPROVED_SCOPE_FILE"], encoding="utf-8") as fh:
            scope = json.load(fh)
        self.assertEqual(scope["agent_request_id"], "req-1")
        self.assertEqual(scope["solution_unique_name"], "Sol")

    def test_service_account_gate_refuses_copilot_target(self):
        os.environ["LIFECYCLE_TARGET"] = "copilot"
        with self.assertRaises(SystemExit):
            run(service_account_gate.main)
        self.assertEqual(self.mock.created, [])

    def test_invalid_target_fails_preflight(self):
        os.environ["LIFECYCLE_TARGET"] = "gcp"
        code, _, err = run(preflight.main)
        self.assertEqual(code, 1)
        self.assertIn("LIFECYCLE_TARGET", err)


class ApiUrlTest(unittest.TestCase):
    def test_https_and_loopback_http_are_allowed(self) -> None:
        for url in ("https://example.com/api/public", "http://127.0.0.1:8080/api", "http://localhost/api"):
            self.assertEqual(api.require_api_url(url), url)

    def test_other_schemes_and_remote_http_are_refused(self) -> None:
        for url in ("http://example.com/api", "file:///etc/passwd", "ftp://example.com/x", "https:///nohost"):
            with self.assertRaises(SystemExit):
                api.require_api_url(url)


if __name__ == "__main__":
    unittest.main()
