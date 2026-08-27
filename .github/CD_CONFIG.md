# CD environment configuration

Create GitHub environment **`agent-lifecycle`**:  
Settings → Environments → New environment → `agent-lifecycle`

Add **variables** and **secrets** on that environment (or at repo level — the workflow uses `environment: agent-lifecycle`).

## Secrets (sensitive — masked in logs)

| Name | Required | Description |
|---|---|---|
| `BALKANID_API_KEY_ID` | Always | Employee API key id |
| `BALKANID_API_KEY_SECRET` | Always | Employee API key secret |
| `AWS_ACCESS_KEY_ID` | When `ENABLE_BEDROCK=true` | IAM principal with `aws/bedrock-agent-lifecycle-iam-policy.json` |
| `AWS_SECRET_ACCESS_KEY` | When `ENABLE_BEDROCK=true` | Matching AWS secret |

## Variables (non-sensitive — visible in logs)

| Name | Required | Default | Description |
|---|---|---|---|
| `ENABLE_BEDROCK` | No | `false` | `true` = create IAM role + Bedrock agent after gate approval; `false` = gate-only |
| `BALKANID_PUBLIC_API_URL` | Yes | — | Public API base URL, e.g. `https://your-tenant.balkanid.app/api/public` |
| `BALKANID_AGENT_OWNER_EMAIL` | Yes | — | Employee who will own the agent (`createRequest.employeeEmail`) |
| `BALKANID_INTEGRATION_ID` | Yes | — | Integration id for `entityFilterGrant` |
| `APPROVAL_WAIT_MINUTES` | No | `120` | Max minutes the gate polls before failing (no AWS resources created) |
| `AGENT_NAME` | No | `demo-support-agent` | Agent / Terraform resource name |
| `AGENT_OWNER_EMAIL` | No | *(empty)* | Owner in access request reason; gate falls back to employee email if unset |
| `AGENT_PURPOSE` | No | `Agent lifecycle CD pipeline demo` | Purpose string in access request reason |
| `AWS_REGION` | No | `us-east-1` | AWS region when `ENABLE_BEDROCK=true` |

### Why secret vs variable?

| Treat as **secret** | Treat as **variable** |
|---|---|
| API key id/secret | Tenant Public API URL |
| AWS access keys | Employee email, integration id |
| Passwords, tokens | `ENABLE_BEDROCK`, region, agent metadata |
| Anything that authenticates | Timeouts, feature flags |

Employee email and integration id are identifiers, not credentials — variables are fine and easier to audit. Rotate API keys via secrets only.

## Per-run workflow overrides

When you **Run workflow**, you can override:

| Workflow input | Overrides variable |
|---|---|
| `agent_name` | `AGENT_NAME` |
| `approval_wait_minutes` | `APPROVAL_WAIT_MINUTES` |

`operation` (`apply` / `destroy`) is always chosen per run.  
`ENABLE_BEDROCK` and other settings come from environment variables only.

## Demo flow

1. Set variables: `ENABLE_BEDROCK=false`, plus BalkanID URL / employee / integration.
2. Set secrets: API key id + secret.
3. Actions → **CD** → Run workflow → `apply`.
4. Approve or deny in BalkanID while the job waits.
5. To test Bedrock: set `ENABLE_BEDROCK=true`, add AWS secrets, run `apply` again.
6. Run `destroy` to tear down AWS resources (uses cached Terraform state).

Bedrock Agents and model access must be enabled in **us-east-1** when `ENABLE_BEDROCK=true`.

State is cached per `AGENT_NAME` + branch (PoV-grade; use an S3 backend for production).
