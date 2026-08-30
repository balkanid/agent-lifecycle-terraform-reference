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
| `ENABLE_BEDROCK` | No | `false` | `true` = create IAM role + AWS agent after gate approval; `false` = gate-only |
| `AGENT_BACKEND` | No | `agentcore` | `agentcore` (AgentCore harness, new accounts) or `classic` (Bedrock Agents Classic, allowlisted accounts) |
| `TRIGGER_INTEGRATION_SYNC` | No | `true` | After successful Terraform apply, call Public API `syncIntegration` for `BALKANID_INTEGRATION_ID` |
| `BALKANID_PUBLIC_API_URL` | Yes | — | Public API base URL, e.g. `https://balkanid.dev/api/public` |
| `BALKANID_AGENT_OWNER_EMAIL` | Yes | — | Employee who will own the agent (`createRequest.employeeEmail`) |
| `BALKANID_INTEGRATION_ID` | When sync enabled | *(empty)* | AWS integration id — used on the access request and for post-apply `syncIntegration` |
| `APPROVAL_WAIT_MINUTES` | No | `120` | Max minutes the gate polls before failing (no AWS resources created) |
| `AGENT_NAME` | No | `demo-support-agent` | Agent / Terraform resource name |
| `AGENT_PURPOSE` | No | `Agent lifecycle CD pipeline demo` | Purpose string passed as `createRequest.reason` |
| `AWS_REGION` | No | `us-east-1` | AWS region when `ENABLE_BEDROCK=true` |
| `AWS_ACCOUNT_ID` | When `ENABLE_BEDROCK=true` | — | 12-digit account id (`aws sts get-caller-identity --query Account --output text`) |

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
| `agent_backend` | `AGENT_BACKEND` (`agentcore` or `classic`) |
| `approval_wait_minutes` | `APPROVAL_WAIT_MINUTES` |

`operation` (`apply` / `destroy`) is always chosen per run.  
`ENABLE_BEDROCK`, `TRIGGER_INTEGRATION_SYNC`, and other settings come from environment variables unless overridden above.

## End-to-end apply flow (`ENABLE_BEDROCK=true`)

```
CD run (apply)
  1. gate.py          → createRequest (AGENT_ACCESS) + poll until approved/denied
  2. if denied        → job fails (no AWS resources)
  3. if approved      → terraform apply (AGENT_BACKEND=agentcore|classic)
  4. if sync enabled  → syncIntegration(integrationId) — AWS extractor discovers new agent
```

Set `BALKANID_INTEGRATION_ID` to the AWS integration in BalkanID. Disable step 4 with `TRIGGER_INTEGRATION_SYNC=false`.

## Demo flow

1. Set variables: `ENABLE_BEDROCK=false`, plus BalkanID URL / employee / integration.
2. Set secrets: API key id + secret.
3. Actions → **CD** → Run workflow → `apply`.
4. Approve or deny in BalkanID while the job waits.
5. To test Bedrock: set `ENABLE_BEDROCK=true`, `BALKANID_INTEGRATION_ID`, add AWS secrets, run `apply` again — after Terraform, CD triggers integration sync automatically.
6. Run `destroy` to tear down AWS resources (uses cached Terraform state). When `AGENT_BACKEND=agentcore`, CD also runs `scripts/cleanup-agentcore-memory.sh` to delete orphan Memory resources that Terraform harness destroy may leave behind.

Bedrock and AgentCore must be enabled in your chosen region when `ENABLE_BEDROCK=true`. Default **`AGENT_BACKEND=agentcore`** works on new AWS accounts; use `classic` only if your account has prior Bedrock Agents Classic usage ([maintenance mode FAQ](https://docs.aws.amazon.com/bedrock/latest/userguide/agents-classic-maintenance-mode.html)).

State is cached per `AGENT_NAME` + branch when `ENABLE_BEDROCK=true` (PoV-grade; use an S3 backend for production).

## Cloudflare / WAF (GitHub-hosted runners)

CD runs `scripts/gate.py` on **GitHub-hosted runners**. Their egress IPs change and are often flagged by Cloudflare managed WAF rules on `*.balkanid.dev` / `*.balkanid.app`.

If the job fails with **HTTP 403** and a Cloudflare “Sorry, you have been blocked” page:

1. **Allowlist GitHub Actions IP ranges** on the tenant zone — fetch current CIDRs from [GitHub meta API](https://api.github.com/meta) (`actions` key), or
2. Add a **WAF skip rule** for `http.request.uri.path starts_with "/api/public"` when `X-Api-Key-Id` is present, or
3. Run CD from a **self-hosted runner** with a stable, allowlisted egress IP.

Gate-only runs (`ENABLE_BEDROCK=false`) still need Public API access from the runner — Terraform is not involved until Bedrock is enabled.
