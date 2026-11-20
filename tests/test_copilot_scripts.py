"""Offline tests for the Copilot Studio scripts. Stdlib only, no network."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
os.environ["BALKANID_SKIP_DOTENV"] = "1"

import entra_agent_identity_gate as identity_gate  # noqa: E402
import publish_copilot_agent as publisher  # noqa: E402
import verify_approved_scope as verify  # noqa: E402


class IdentityGatePayloadTest(unittest.TestCase):
    def build(self, **env: str) -> dict:
        with mock.patch.dict(os.environ, env, clear=False):
            return identity_gate.create_input(
                "owner@example.com", "00000000-0000-0000-0000-000000000000", "contoso-agent"
            )

    def test_request_type_decides_identity_not_payload(self) -> None:
        body = self.build()
        self.assertEqual(body["requestType"], "CREATE_SERVICE_ACCOUNT")
        entity = body["payload"]["entity"]
        self.assertNotIn("identityType", entity)
        self.assertNotIn("identityType", json.dumps(body))
        self.assertEqual(entity["name"], "contoso-agent")
        self.assertEqual(entity["sourceType"], "entra service principal")

    def test_graph_permissions_are_listed_for_the_approver(self) -> None:
        body = self.build(ENTRA_GRAPH_PERMISSIONS="Sites.Selected, User.Read.All")
        scim = body["payload"]["entity"]["scimPayload"]
        self.assertEqual(scim["graph_application_permissions"], ["Sites.Selected", "User.Read.All"])


class PublishLoggingTest(unittest.TestCase):
    def test_client_secret_is_masked_in_logs(self) -> None:
        shown = publisher.printable(["auth", "create", "--clientSecret", "hunter2", "--tenant", "t"])
        self.assertNotIn("hunter2", shown)
        self.assertIn("--tenant t", shown)


class VerifyApprovedScopeTest(unittest.TestCase):
    def run_verify(self, approved: dict, _unset: tuple = (), **env: str) -> int:
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "approved.json")
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(approved, fh)
            clean = {
                k: ""
                for k in (
                    "AGENT_NAME",
                    "POWER_PLATFORM_ENVIRONMENT_ID",
                    "SOLUTION_UNIQUE_NAME",
                    "ENTRA_IDENTITY_DISPLAY_NAME",
                    "ENTRA_GRAPH_PERMISSIONS",
                    "AGENT_SCHEMA_NAME",
                    "AGENT_BOT_ID",
                )
            }
            with mock.patch.dict(os.environ, {**clean, **env, "APPROVED_SCOPE_FILE": path}):
                for k in _unset:
                    os.environ.pop(k, None)
                with mock.patch.object(sys, "stderr"), mock.patch("builtins.print"):
                    return verify.main()

    def approved(self, **extra: object) -> dict:
        return {
            "agent_request_id": "req-1",
            "agent_name": "contoso-agent",
            "copilot_surface": "copilot-studio",
            "environment_id": "env-1",
            "solution_unique_name": "ContosoSolution",
            "agent_schema_name": "",
            "agent_bot_id": "",
            **extra,
        }

    def test_match_passes(self) -> None:
        code = self.run_verify(
            self.approved(),
            AGENT_NAME="contoso-agent",
            POWER_PLATFORM_ENVIRONMENT_ID="env-1",
            SOLUTION_UNIQUE_NAME="ContosoSolution",
        )
        self.assertEqual(code, 0)

    def test_environment_mismatch_fails(self) -> None:
        code = self.run_verify(
            self.approved(),
            AGENT_NAME="contoso-agent",
            POWER_PLATFORM_ENVIRONMENT_ID="env-OTHER",
            SOLUTION_UNIQUE_NAME="ContosoSolution",
        )
        self.assertEqual(code, 1)

    def test_missing_field_from_a_gate_that_ran_fails_closed(self) -> None:
        approved = self.approved()
        del approved["environment_id"]
        code = self.run_verify(
            approved,
            AGENT_NAME="contoso-agent",
            POWER_PLATFORM_ENVIRONMENT_ID="env-OTHER",
            SOLUTION_UNIQUE_NAME="ContosoSolution",
        )
        self.assertEqual(code, 1)

    def test_added_graph_permission_fails(self) -> None:
        code = self.run_verify(
            self.approved(graph_application_permissions=["Sites.Selected"]),
            AGENT_NAME="contoso-agent",
            POWER_PLATFORM_ENVIRONMENT_ID="env-1",
            SOLUTION_UNIQUE_NAME="ContosoSolution",
            ENTRA_GRAPH_PERMISSIONS="Sites.Selected,Mail.ReadWrite",
        )
        self.assertEqual(code, 1)

    def test_permissions_without_identity_approval_fail_closed(self) -> None:
        code = self.run_verify(
            self.approved(),
            AGENT_NAME="contoso-agent",
            POWER_PLATFORM_ENVIRONMENT_ID="env-1",
            SOLUTION_UNIQUE_NAME="ContosoSolution",
            ENTRA_GRAPH_PERMISSIONS="Mail.ReadWrite",
        )
        self.assertEqual(code, 1)

    def test_changed_publish_target_fails(self) -> None:
        code = self.run_verify(
            self.approved(agent_schema_name="bkn_approved"),
            AGENT_NAME="contoso-agent",
            POWER_PLATFORM_ENVIRONMENT_ID="env-1",
            SOLUTION_UNIQUE_NAME="ContosoSolution",
            AGENT_SCHEMA_NAME="bkn_other",
        )
        self.assertEqual(code, 1)

    def test_unset_agent_name_compares_as_the_gate_default(self) -> None:
        code = self.run_verify(
            self.approved(agent_name="example-trial-intake-agent", entra_display_name="example-trial-intake-agent",
                          identity_request_id="req-2", graph_application_permissions=[]),
            _unset=("AGENT_NAME",),
            POWER_PLATFORM_ENVIRONMENT_ID="env-1",
            SOLUTION_UNIQUE_NAME="ContosoSolution",
        )
        self.assertEqual(code, 0)

    def test_record_without_request_id_is_not_an_approval(self) -> None:
        self.assertEqual(self.run_verify({"agent_name": "contoso-agent"}), 2)


if __name__ == "__main__":
    unittest.main()
