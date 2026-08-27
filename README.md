# Agent lifecycle PoV

Reference implementation showing how **infrastructure-as-code** (Terraform) can gate AI agent creation on **BalkanID policy approval** before any cloud resources are provisioned.

This repository is a **customer-facing adapter pattern**, not BalkanID product code. Use it in demos, design partnerships, and as a starting point when a prospect asks for agent lifecycle governance without a runtime gateway.

## What this demonstrates

Many teams deploy agents via Terraform, Helm, or CI pipelines. IAM often learns about those agents after the fact. BalkanID sits **before creation**:

1. IaC calls BalkanID (access request).
2. BalkanID evaluates policy (auto-approve, manual approval, or deny).
3. On approval, IaC continues and creates the agent in the cloud.
4. BalkanID is the system of record for owner, approval evidence, and linked identities.

This is **lifecycle and policy enforcement**, not runtime authorization. A separate tool (e.g. a JIT gateway) can still gate actions at invoke time.

```
Terraform apply
    → createRequest AGENT_ACCESS (BalkanID Public API, requestType: agent_access_request)
    → policy evaluation
    → [pending] human approval in BalkanID UI
    → approved → apply continues → AWS Bedrock agent (optional)
    → AWS extractor sync discovers agent in BalkanID; map IAM identity to owner
```

Outbound webhooks (`request.actioned`) can notify customer automation when approval completes. This PoV polls the Public API; either approach is valid.

## CI / CD

### CI (every PR and push to `main`)

[`.github/workflows/ci.yml`](.github/workflows/ci.yml):

- Python compile check for `scripts/gate.py`
- `terraform fmt` / `validate` (gate-only; dummy vars, no live credentials)
- IAM policy JSON validation
- TruffleHog secret scan

### CD (manual — demo pipeline waits on BalkanID)

[`.github/workflows/cd.yml`](.github/workflows/cd.yml) runs **`terraform apply` in GitHub Actions**. The job blocks on the same gate as local apply:

```
GitHub Actions: terraform apply
    → gate.py → createRequest (AGENT_ACCESS)
    → [job waiting — approve/deny in BalkanID UI]
    → approved → apply continues → optional Bedrock resources
    → denied → job fails, nothing in AWS
```

**Setup:** create GitHub environment `agent-lifecycle` and configure **variables + secrets** per [`.github/CD_CONFIG.md`](.github/CD_CONFIG.md).

**Run:** Actions → CD → Run workflow

| Source | Examples |
|---|---|
| **Environment variables** | `ENABLE_BEDROCK`, `BALKANID_PUBLIC_API_URL`, `APPROVAL_WAIT_MINUTES`, `AGENT_NAME` |
| **Environment secrets** | `BALKANID_API_KEY_ID`, `BALKANID_API_KEY_SECRET`, `AWS_*` (when Bedrock enabled) |
| **Per-run workflow inputs** | `operation`, optional overrides for `agent_name`, `approval_wait_minutes` |

While the job is running, open Access Requests in BalkanID and approve or deny.

**How long it waits:** nothing is created in AWS until approval. The gate polls every 5 seconds until approved, denied, or **`APPROVAL_WAIT_MINUTES`** is reached (environment variable, default **120**). Job timeout = that value + 20 minutes.
| Layer | Default | Configurable via |
|---|---|---|
| Gate poll (`gate.py`) | 15 min locally | `POLL_TIMEOUT_SECONDS` in `.env` or `poll_timeout_seconds` tfvar |
| CD workflow | **120 min** | `APPROVAL_WAIT_MINUTES` environment variable (or per-run override) |
| GitHub job hard limit | 6 hours | GitHub plan / repo settings |

If approval often takes **longer than a few hours**, a single blocking job is the wrong shape — use BalkanID **`request.actioned` webhooks** to resume the pipeline (or re-run CD after approval). Polling for days is not viable in GitHub Actions.

Customers can mirror this pattern in their own CI (GitHub Actions, GitLab, Jenkins, etc.) — the gate is just `python3 scripts/gate.py` before or inside Terraform.

## Repository layout

```
agent-lifecycle-terraform-pov/
├── scripts/gate.py          # Public API createRequest (AGENT_ACCESS) + poll until terminal
├── terraform/               # Blocks apply on gate; optional Bedrock agent resource
├── aws/                     # Least-privilege IAM policy for demo AWS accounts
└── env.example              # Configuration template (copy to .env, never commit)
```

## Prerequisites

**BalkanID tenant**

- Agents enabled (`product-nhi`, `product-nhi-agents` feature flags).
- At least one connected integration (used in the access request grant filter).
- Employee API key with permission to call `createRequest` on the [Public API](https://docs.balkan.id/).
- Access-request policy configured for your demo (e.g. require approver; fail closed on deny).
- Optional: webhook destination subscribed to `request.created` and `request.actioned`.

**Local tooling**

- Python 3.11+ (stdlib only for `gate.py`).
- Terraform 1.5+.

**AWS (optional)**

- Only required when `enable_bedrock=true`.
- Bedrock enabled in **us-east-1** (Bedrock Agents are not available in all regions).
- Foundation model access (default: Amazon Nova Micro).
- IAM permissions per `aws/bedrock-agent-lifecycle-iam-policy.json`.

## Quick start — gate only (no AWS)

1. Copy configuration:

   ```bash
   cp env.example .env
   # Edit .env: API keys, tenant URL, agent owner email, optional integration id
   ```

2. Run the gate script:

   ```bash
   set -a && source .env && set +a
   python3 scripts/gate.py
   ```

   The script creates an access request and polls until it is approved or denied. Exit code `0` = approved, `1` = denied or timeout.

3. Approve or deny the request in BalkanID while the script is running.

## Terraform

Gate-only (no AWS credentials required):

```bash
cd terraform
terraform init
terraform apply \
  -var="enable_bedrock=false" \
  -var="api_key_id=$API_KEY_ID" \
  -var="api_key_secret=$API_KEY_SECRET" \
  -var="agent_owner_email=$AGENT_OWNER_EMAIL" \
  -var="integration_id=$INTEGRATION_ID"
```

`terraform apply` **blocks** until BalkanID approves the request. Denial fails the apply.

With Bedrock (after AWS is configured):

```bash
export AWS_PROFILE=your-profile   # us-east-1
terraform apply \
  -var="enable_bedrock=true" \
  -var="api_key_id=$API_KEY_ID" \
  -var="api_key_secret=$API_KEY_SECRET" \
  -var="agent_owner_email=$AGENT_OWNER_EMAIL" \
  -var="integration_id=$INTEGRATION_ID"
```

After a successful apply with Bedrock enabled, run an AWS integration sync — the agent is discovered via the extractor (no manual agent registration API call).

### Variables

| Variable | Description |
|---|---|
| `enable_bedrock` | When `false`, only runs the BalkanID gate. Default `false`. |
| `balkanid_public_api_url` | Public API base URL for your tenant. |
| `api_key_id`, `api_key_secret` | Employee API key (sensitive). |
| `agent_owner_email` | Employee who will own the agent. |
| `integration_id` | Integration id for `entityFilterGrant`. |
| `agent_name` | Agent name embedded in the request reason and Bedrock resource. |
| `agent_owner_email`, `agent_purpose`, `intended_iam_role_arn` | Metadata carried in the request reason string. |
| `foundation_model` | Bedrock model id when `enable_bedrock=true`. |

Pass secrets via `-var`, `TF_VAR_*`, or a gitignored `terraform.tfvars` file.

## AWS IAM policy

Attach `aws/bedrock-agent-lifecycle-iam-policy.json` to the role or user running Terraform. It scopes IAM role creation to path `/balkanid-agent-lifecycle/` and allows Bedrock agent management APIs. Adjust the account id in `INTENDED_IAM_ROLE_ARN` / tfvars for your environment.

## How this uses BalkanID APIs today

| Capability | Where it lives | Used by this PoV? |
|---|---|---|
| **`createRequest` (`AGENT_ACCESS`)** | Public API — unified mutation, `agent_access_request` stored type | **Yes** — gate script calls this. |
| **`createAgents`** | Tenant GraphQL only — `pipeline/tenant-command/...` | **No** — agents are not pre-created; AWS extractor sync discovers them after external provisioning. |
| **`request.actioned` webhook** | Outbound webhooks (`pkg/webhooks/topics.go`) | Optional — PoV polls instead. |

The gate sends structured agent intent (`ownerEmail`, `action: CREATE`, `name`, `agentType`, optional `integrationId` and `intendedIamRoleArn`). BalkanID stores the request only — no agent entity is created upfront. After external provisioning and AWS integration sync, the agent appears in BalkanID for owner mapping and governance.

## Suggested demo narrative (~8 minutes)

1. **Problem:** agents created by platform teams without IAM visibility.
2. **Gate:** `terraform apply` waits on BalkanID; show the pending access request.
3. **Policy:** show approval rules; optional second apply that auto-denies.
4. **Webhook or poll:** show `request.actioned` (or script exiting on approve).
5. **Payload:** Bedrock agent appears only after approval (if enabled).
6. **SoR:** AWS extractor sync shows agent in BalkanID with owner and mapped IAM identity.
7. **Positioning:** BalkanID governs lifecycle; runtime gateways remain separate.

## Out of scope

- Runtime / invoke-time gateway
- Bedrock or Kubernetes extractors (discovery of agents created outside BalkanID)
- Inbound webhook gateway (EN-8766) — Terraform calls Public API directly
- Production hardening (idempotency, ASSIGN/UNASSIGN/DELETE agent access actions, synchronous policy API)

## Related product work

- [EN-8866](https://balkanid.atlassian.net/browse/EN-8866) — agent lifecycle management (example design-partner use case)
- [EN-8766](https://balkanid.atlassian.net/browse/EN-8766) — generic inbound webhook gateway (future ingestion path)
