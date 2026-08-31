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
| `PROVISION_AWS_AGENT` | No | `false` | **`true`** to provision an AWS agent (AgentCore harness or Classic agent) after gates. `false` = gates only. |
| `SERVICE_ACCOUNT_GATE` | No | `false` | **`true`** to run `CREATE_SERVICE_ACCOUNT` approval gate before the agent gate. |
| `AGENT_GATE` | No | `true` | **`true`** to run `AGENT_ACCESS` approval gate (`gate.py`). |
| `POLL_SECONDS` | No | `5` | Seconds between approval status polls. |
| `AGENT_BACKEND` | No | `agentcore` | When `PROVISION_AWS_AGENT=true`: `agentcore` (new accounts) or `classic` (allowlisted Classic accounts). |
| `TRIGGER_INTEGRATION_SYNC` | No | `true` | After successful Terraform apply, call Public API `syncIntegration` |
| `BALKANID_PUBLIC_API_URL` | Yes (or secret) | — | Public API base URL, e.g. `https://your-tenant.balkanid.app/api/public` |
| `BALKANID_AGENT_OWNER_EMAIL` | Yes (or secret) | — | Employee who will own the agent |
| `BALKANID_INTEGRATION_ID` | When sync enabled (or secret) | *(empty)* | AWS integration id |
| `APPROVAL_WAIT_MINUTES` | No | `120` | Max minutes each gate polls before failing (no AWS resources created) |
| `AGENT_NAME` | No | `demo-support-agent` | Agent / Terraform resource name |
| `AGENT_PURPOSE` | No | `Agent provisioned via Terraform with BalkanID approval` | Purpose string passed as `createRequest.reason` |
| `SERVICE_ACCOUNT_POLICY_NAME` | When `SERVICE_ACCOUNT_GATE=true` | `AmazonBedrockFullAccess` | Managed policy name for policy review on create request |
| `SERVICE_ACCOUNT_ROLE_NAME` | No | same as `AGENT_NAME` | IAM service role name Terraform will create |
| `AWS_REGION` | No | `us-east-1` | AWS region when `PROVISION_AWS_AGENT=true` |
| `AWS_ACCOUNT_ID` | Optional | — | Used for intended IAM role ARN on gates when AWS secrets are not set |

Account id for Terraform IAM trust policies is resolved at runtime via `aws sts get-caller-identity` when AWS secrets are configured. Local runs can set `AWS_ACCOUNT_ID` in `.env` — see `scripts/terraform-local.sh`.

### Why secret vs variable?

| Treat as **secret** | Treat as **variable** |
|---|---|
| API key id/secret | `PROVISION_AWS_AGENT`, `AGENT_BACKEND`, region |
| AWS access keys | Agent name, purpose, timeouts, poll interval |
| Tenant URL, employee email, integration id (recommended) | Non-identifying workflow toggles |

Employee email and integration id can be variables for convenience; use **secrets** if you want them masked in workflow logs. See [SECURITY.md](../SECURITY.md).

## Per-run workflow overrides

When you **Run workflow**, dropdowns default to **`use-env`** (read from environment variables). Only `agent_name` is free text (blank = env var).

| Workflow input | Type | Overrides variable |
|---|---|---|
| `operation` | dropdown | — (always per run) |
| `provision_aws_agent` | dropdown (`use-env` / `true` / `false`) | `PROVISION_AWS_AGENT` |
| `service_account_gate` | dropdown (`use-env` / `true` / `false`) | `SERVICE_ACCOUNT_GATE` |
| `agent_gate` | dropdown (`use-env` / `true` / `false`) | `AGENT_GATE` |
| `agent_backend` | dropdown (`use-env` / `agentcore` / `classic`) | `AGENT_BACKEND` |
| `trigger_integration_sync` | dropdown (`use-env` / `true` / `false`) | `TRIGGER_INTEGRATION_SYNC` |
| `approval_wait_minutes` | dropdown (`use-env` / 30 / 60 / 120 / 240 / 360) | `APPROVAL_WAIT_MINUTES` |
| `poll_seconds` | dropdown (`use-env` / 5 / 10 / 15 / 30 / 60) | `POLL_SECONDS` |
| `agent_name` | text (optional) | `AGENT_NAME` |

## End-to-end apply flow (`PROVISION_AWS_AGENT=true`)

**Agent gate only (default):**

```
CD run (apply)
  1. gate.py           → AGENT_ACCESS + poll until approved/denied
  2. terraform apply   → IAM role + harness/agent
  3. syncIntegration
```

**Service account + agent gates:**

```
CD run (apply)
  1. service_account_gate.py → CREATE_SERVICE_ACCOUNT (approval only)
  2. gate.py                 → AGENT_ACCESS (approval only)
  3. terraform apply         → IAM role + harness/agent
  4. syncIntegration
```

Gates wait for **approval only** — Terraform provisions AWS resources. **Disable app provisioning** on the demo AWS integration when using `SERVICE_ACCOUNT_GATE=true`; otherwise BalkanID may create an IAM role at `/` with the same name as `AGENT_NAME`, which blocks Terraform (scoped to `/balkanid-agent-lifecycle/`).

Set `BALKANID_INTEGRATION_ID` to your AWS integration in BalkanID. Disable sync with `TRIGGER_INTEGRATION_SYNC=false`.

## Demo flow

1. Set variables: `SERVICE_ACCOUNT_GATE=true`, `AGENT_GATE=true`, `PROVISION_AWS_AGENT=true`, plus BalkanID URL, employee email, and integration id.
2. Set secrets: API key id + secret, AWS credentials.
3. Actions → **CD** → Run workflow → `apply`.
4. Approve each request in BalkanID while the job waits.
5. Run `destroy` to tear down AWS resources (uses cached Terraform state). When `AGENT_BACKEND=agentcore`, CD also runs harness + memory cleanup for AgentCore resources Terraform may leave behind.

Bedrock and AgentCore must be enabled in your chosen region when `PROVISION_AWS_AGENT=true`. Default **`AGENT_BACKEND=agentcore`** works on new AWS accounts.

Terraform state is cached per `AGENT_NAME` + branch when `PROVISION_AWS_AGENT=true`. For production, use a remote backend (for example S3 with locking).

**Re-run vs new dispatch:** GitHub **“Re-run failed jobs”** reuses the commit from the original run. After fixes land on `main`, use **Actions → CD → Run workflow** (new dispatch) so the job checks out the latest code.
