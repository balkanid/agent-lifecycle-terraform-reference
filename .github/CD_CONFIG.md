# CD environment configuration

Create GitHub environment **`agent-lifecycle`**:  
Settings → Environments → New environment → `agent-lifecycle`

Add **variables** and **secrets** on that environment (or at repo level — the workflow uses `environment: agent-lifecycle`).

## Secrets (sensitive — masked in logs)

| Name | Required | Description |
|---|---|---|
| `BALKANID_API_KEY_ID` | Always | Employee API key id |
| `BALKANID_API_KEY_SECRET` | Always | Employee API key secret |
| `AWS_ACCESS_KEY_ID` | When `PROVISION_AWS_AGENT=true` | IAM user with **full** [`aws/bedrock-agent-lifecycle-iam-policy.json`](../aws/bedrock-agent-lifecycle-iam-policy.json) |
| `AWS_SECRET_ACCESS_KEY` | When `PROVISION_AWS_AGENT=true` | Matching AWS secret |
| `BALKANID_PUBLIC_API_URL` | Recommended as secret | Public API base URL — use a **secret** (not variable) to keep tenant URL out of workflow logs |
| `BALKANID_AGENT_OWNER_EMAIL` | Recommended as secret | Agent owner email — use a **secret** if you do not want employee email in logs |
| `BALKANID_INTEGRATION_ID` | Recommended as secret when set | Integration id — use a **secret** if you do not want it in logs |

When the same name exists as both secret and variable, the workflow uses the **secret**.

## Variables (non-sensitive — visible in logs)

| Name | Required | Default | Description |
|---|---|---|---|
| `PROVISION_AWS_AGENT` | No | `false` | **`true`** to provision an AWS agent (AgentCore harness or Classic agent) after gate approval. `false` = gate-only. |
| `AGENT_BACKEND` | No | `agentcore` | When `PROVISION_AWS_AGENT=true`: `agentcore` (new accounts) or `classic` (allowlisted Classic accounts). |
| `TRIGGER_INTEGRATION_SYNC` | No | `true` | After successful Terraform apply, call Public API `syncIntegration` |
| `BALKANID_PUBLIC_API_URL` | Yes (or secret) | — | Public API base URL, e.g. `https://your-tenant.balkanid.app/api/public` |
| `BALKANID_AGENT_OWNER_EMAIL` | Yes (or secret) | — | Employee who will own the agent |
| `BALKANID_INTEGRATION_ID` | When sync enabled (or secret) | *(empty)* | AWS integration id |
| `APPROVAL_WAIT_MINUTES` | No | `120` | Max minutes the gate polls before failing (no AWS resources created) |
| `AGENT_NAME` | No | `demo-support-agent` | Agent / Terraform resource name |
| `AGENT_PURPOSE` | No | `Agent provisioned via Terraform with BalkanID approval` | Purpose string passed as `createRequest.reason` |
| `AWS_REGION` | No | `us-east-1` | AWS region when `PROVISION_AWS_AGENT=true` |

Account id for Terraform IAM trust policies is resolved at runtime via `aws sts get-caller-identity`. Local runs can set `AWS_ACCOUNT_ID` in `.env` — see `scripts/terraform-local.sh`.

### Why secret vs variable?

| Treat as **secret** | Treat as **variable** |
|---|---|
| API key id/secret | `PROVISION_AWS_AGENT`, `AGENT_BACKEND`, region |
| AWS access keys | Agent name, purpose, timeouts |
| Tenant URL, employee email, integration id (recommended) | Non-identifying workflow toggles |

Employee email and integration id can be variables for convenience, but **secrets are recommended** for public repositories so they are masked in logs. See [SECURITY.md](../SECURITY.md).

## Per-run workflow overrides

When you **Run workflow**, dropdowns default to **`use-env`** (read from environment variables). Only `agent_name` is free text (blank = env var).

| Workflow input | Type | Overrides variable |
|---|---|---|
| `operation` | dropdown | — (always per run) |
| `provision_aws_agent` | dropdown (`use-env` / `true` / `false`) | `PROVISION_AWS_AGENT` |
| `agent_backend` | dropdown (`use-env` / `agentcore` / `classic`) | `AGENT_BACKEND` |
| `trigger_integration_sync` | dropdown (`use-env` / `true` / `false`) | `TRIGGER_INTEGRATION_SYNC` |
| `approval_wait_minutes` | dropdown (`use-env` / 30 / 60 / 120 / 240 / 360) | `APPROVAL_WAIT_MINUTES` |
| `agent_name` | text (optional) | `AGENT_NAME` |

## End-to-end apply flow (`PROVISION_AWS_AGENT=true`)

```
CD run (apply)
  1. gate.py          → createRequest (AGENT_ACCESS) + poll until approved/denied
  2. if denied        → job fails (no AWS resources)
  3. if approved      → terraform apply (AGENT_BACKEND=agentcore|classic)
  4. if sync enabled  → syncIntegration(integrationId)
```

Set `BALKANID_INTEGRATION_ID` to your AWS integration in BalkanID. Disable step 4 with `TRIGGER_INTEGRATION_SYNC=false`.

## Demo flow

1. Set variables: `PROVISION_AWS_AGENT=false`, plus BalkanID URL, employee email, and integration id.
2. Set secrets: API key id + secret.
3. Actions → **CD** → Run workflow → `apply`.
4. Approve or deny in BalkanID while the job waits.
5. To provision AWS agents: set `PROVISION_AWS_AGENT=true`, `BALKANID_INTEGRATION_ID`, add AWS secrets, run `apply` again.
6. Run `destroy` to tear down AWS resources (uses cached Terraform state). When `AGENT_BACKEND=agentcore`, CD also runs memory cleanup for orphan AgentCore resources.

Bedrock and AgentCore must be enabled in your chosen region when `PROVISION_AWS_AGENT=true`. Default **`AGENT_BACKEND=agentcore`** works on new AWS accounts.

Terraform state is cached per `AGENT_NAME` + branch when `PROVISION_AWS_AGENT=true`. For production, use a remote backend (for example S3 with locking).

**Re-run vs new dispatch:** GitHub **“Re-run failed jobs”** reuses the commit from the original run. After fixes land on `main`, use **Actions → CD → Run workflow** (new dispatch) so the job checks out the latest code.
