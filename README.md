# BalkanID agent access requests — Terraform reference

Reference implementation showing how to gate AI agent creation on **BalkanID policy approval** before provisioning cloud resources.

Use this repository as a starting point when your team deploys agents via Terraform, Helm, or CI/CD and wants BalkanID to govern **who may create agents**, **who owns them**, and **what was approved** — without replacing your existing IaC workflow.

## What this demonstrates

Many teams deploy agents through infrastructure-as-code. IAM and security teams often learn about those agents only after they exist. This pattern puts BalkanID **before creation**:

1. Your pipeline calls the BalkanID Public API (`createRequest` with type `AGENT_ACCESS`).
2. BalkanID evaluates your access-request policies (auto-approve, manual approval, or deny).
3. On approval, the pipeline continues and creates the agent in AWS (optional in this repo).
4. BalkanID remains the system of record for owner, approval evidence, and linked identities.

This is **lifecycle and policy enforcement**, not runtime authorization. You can still add invoke-time controls (for example a JIT gateway) separately.

```
Terraform / CI apply
    → createRequest (AGENT_ACCESS)
    → policy evaluation
    → [pending] approver action in BalkanID
    → approved → provision AWS agent (Bedrock Classic or AgentCore harness, optional)
    → syncIntegration → integration sync discovers the agent in BalkanID
```

When approval completes, BalkanID can also notify your automation via the **`request.actioned` webhook**. This reference polls the Public API; either approach works in production.

## Repository layout

```
├── scripts/gate.py          # createRequest (AGENT_ACCESS) + poll until terminal status
├── scripts/lifecycle.py     # EN-8896 JIT identity lifecycle orchestrator
├── scripts/balkanid_api.py  # Shared Public API helpers
├── scripts/trigger_sync.py  # syncIntegration after AWS resources are created
├── terraform/               # Gate-only stack (local-exec) + optional Bedrock module
├── aws/                     # Example least-privilege IAM policy for Terraform
└── env.example              # Configuration template (copy to .env — never commit)
```

## Prerequisites

**BalkanID**

- Agent access requests enabled on your tenant (ask your BalkanID administrator if the option is not visible).
- At least one connected integration (for example AWS), used in the access request and optional post-provision sync.
- Employee API key with permission to call `createRequest` on the [Public API](https://docs.balkan.id/).
- Access-request policy configured for your organization (for example require approver; fail closed on deny).
- Optional: webhook destination subscribed to `request.actioned` for async pipeline resume.

**Local tooling**

- Python 3.11+ (stdlib only — no pip install required).
- Terraform 1.5+.

**AWS (optional)**

- Only required when provisioning agents (`PROVISION_AWS_AGENT=true` in CD, or `./scripts/terraform-local.sh apply-bedrock` locally).
- Amazon Bedrock enabled in your chosen region ([AgentCore regions](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-regions.html)).
- Foundation model access (default in this repo: Amazon Nova Micro).
- IAM permissions per [`aws/bedrock-agent-lifecycle-iam-policy.json`](aws/bedrock-agent-lifecycle-iam-policy.json).
- **New AWS accounts** should use **`AGENT_BACKEND=agentcore`**. Classic Bedrock Agents are in [maintenance mode](https://docs.aws.amazon.com/bedrock/latest/userguide/agents-classic-maintenance-mode.html) for accounts without prior usage.

## Quick start — gate only (no AWS)

1. Copy configuration:

   ```bash
   cp env.example .env
   # Edit .env: Public API URL, API keys, agent owner email, optional integration id
   ```

2. Run the gate:

   ```bash
   set -a && source .env && set +a
   python3 scripts/gate.py
   ```

   Exit code `0` = approved, `1` = denied or timeout.

3. Approve or deny the request in BalkanID while the script runs.

## Terraform

**Gate only** (no AWS credentials):

```bash
cd terraform
terraform init
terraform apply \
  -var="run_balkanid_gate=true" \
  -var="api_key_id=$API_KEY_ID" \
  -var="api_key_secret=$API_KEY_SECRET" \
  -var="agent_owner_email=$BALKANID_AGENT_OWNER_EMAIL" \
  -var="integration_id=$INTEGRATION_ID"
```

`terraform apply` blocks until BalkanID approves. Denial fails the apply.

**With AWS Bedrock** (after configuring `.env` and IAM):

```bash
./scripts/terraform-local.sh apply-bedrock
```

Set `AGENT_BACKEND=agentcore` (default) for new accounts, or `classic` if your account supports Bedrock Agents Classic.

When `TRIGGER_INTEGRATION_SYNC=true` and `INTEGRATION_ID` is set, `apply-bedrock` runs gate → Terraform → `syncIntegration`.

### JIT identity lifecycle (EN-8896)

Full demo flow: BalkanID creates the IAM service role and assigns entitlements, then Terraform creates only the AgentCore harness against that role:

```bash
# .env: LIFECYCLE_MODE=true, LIFECYCLE_POLICY_NAME=<managed policy in graph>, plus standard vars
./scripts/terraform-local.sh apply-lifecycle
```

Teardown (harness first, then delete the BalkanID-provisioned role):

```bash
./scripts/terraform-local.sh destroy-lifecycle
```

In GitHub CD, set environment variable `LIFECYCLE_MODE=true` (or override per run) with `PROVISION_AWS_AGENT=true`. See [`.github/CD_CONFIG.md`](.github/CD_CONFIG.md).

### Teardown and re-runs (AgentCore)

```bash
./scripts/terraform-local.sh destroy-bedrock
./scripts/terraform-local.sh apply-bedrock
```

`apply-bedrock` and the CD workflow run orphan cleanup before AgentCore apply when reusing the same `AGENT_NAME`. Alternatively, use a fresh agent name each run.

### Variables

| Variable | Description |
|---|---|
| `run_balkanid_gate` | When `true`, runs the gate via Terraform local-exec. CD runs `gate.py` in the workflow instead. |
| `balkanid_public_api_url` | Public API base URL for your tenant. |
| `api_key_id`, `api_key_secret` | Employee API key (sensitive). |
| `agent_owner_email` | Employee who will own the agent. |
| `integration_id` | Optional integration id on the access request. |
| `agent_name` | Agent name in the request and AWS resource. |
| `agent_backend` | `agentcore` (default) or `classic`. |
| `agent_purpose`, `intended_iam_role_arn` | Optional metadata on the access request. |
| `foundation_model` | Bedrock model id for Classic agent or AgentCore harness. |

Pass secrets via `-var`, `TF_VAR_*`, or a gitignored `terraform.tfvars` file.

## Security

See [SECURITY.md](SECURITY.md) for reporting security issues and configuring GitHub Actions secrets.

## CI / CD (GitHub Actions)

### CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) validates Python, Terraform, and IAM policy JSON on every push/PR.

### CD

[`.github/workflows/cd.yml`](.github/workflows/cd.yml) runs the same gate in GitHub Actions, then optionally `terraform apply` and `syncIntegration`:

```
GitHub Actions: gate.py → createRequest (AGENT_ACCESS)
    → [job waiting — approve/deny in BalkanID]
    → approved → (PROVISION_AWS_AGENT=true) terraform apply
    → (TRIGGER_INTEGRATION_SYNC=true) syncIntegration
    → denied → job fails, no AWS resources
```

**Setup:** create GitHub environment `agent-lifecycle` per [`.github/CD_CONFIG.md`](.github/CD_CONFIG.md).

**Run:** Actions → CD → Run workflow.

| Source | Examples |
|---|---|
| **Environment variables** | `PROVISION_AWS_AGENT`, `AGENT_BACKEND`, `TRIGGER_INTEGRATION_SYNC`, `BALKANID_PUBLIC_API_URL`, `BALKANID_INTEGRATION_ID`, `APPROVAL_WAIT_MINUTES`, `AGENT_NAME` |
| **Environment secrets** | `BALKANID_API_KEY_ID`, `BALKANID_API_KEY_SECRET`, `AWS_*` (when provisioning) |
| **Per-run inputs** | `operation`, `provision_aws_agent`, `agent_backend`, `trigger_integration_sync`, `approval_wait_minutes`, optional `agent_name` |

The gate polls every 5 seconds until approved, denied, or **`APPROVAL_WAIT_MINUTES`** (default **120**). For approvals that may take hours or days, use **`request.actioned` webhooks** to resume your pipeline instead of long-running jobs.

You can mirror this pattern in GitLab CI, Jenkins, Azure DevOps, or any runner — the gate is `python3 scripts/gate.py` before or inside Terraform.

## AWS IAM policy

Attach [`aws/bedrock-agent-lifecycle-iam-policy.json`](aws/bedrock-agent-lifecycle-iam-policy.json) to the IAM user or role that runs Terraform. **Replace the entire policy in AWS** (do not merge actions incrementally) — see [`aws/PERMISSIONS.md`](aws/PERMISSIONS.md). IAM role management is scoped to path `/balkanid-agent-lifecycle/`.

## BalkanID Public API usage

| API | Role in this reference |
|---|---|
| **`createRequest` (`AGENT_ACCESS`)** | Creates the agent access request before provisioning. Called by `scripts/gate.py` (classic) or `scripts/lifecycle.py` (JIT mode). |
| **`createRequest` (`CREATE_SERVICE_ACCOUNT`)** | JIT mode: BalkanID provisioner creates an AWS service role for AgentCore. |
| **`createRequest` (`SERVICE_ACCOUNT_ASSIGNMENT`)** | JIT mode: attach managed policies (and optional duration) to the service role. |
| **`createRequest` (`DELETE_SERVICE_ACCOUNT`)** | JIT teardown: delete the provisioned service role after harness destroy. |
| **`requests` query** | Polls request status until approved or denied. |
| **`identities` query** | Resolves provisioned service role entity id after create. |
| **`syncIntegration`** | Triggers integration sync so BalkanID discovers the AWS agent after Terraform creates it. |

The gate sends structured intent: owner email, `CREATE` action, agent name, agent type, and optional integration id and intended IAM role ARN. BalkanID stores the request; the agent entity appears after external provisioning and integration sync.

See the [BalkanID Public API documentation](https://docs.balkan.id/) for request shapes, authentication, and webhooks.

## Example evaluation flow

1. **Problem:** agents created by platform teams without central visibility.
2. **Gate:** run `terraform apply` or CD and show the pipeline waiting on BalkanID.
3. **Policy:** configure approval rules; demonstrate an approved and a denied request.
4. **Provision:** create the AWS agent only after approval (if enabled).
5. **Governance:** run integration sync and confirm owner and IAM identity mapping in BalkanID.

## Production considerations

This repository is a **reference**, not a production deployment template. Before adopting in production, plan for:

- Remote Terraform state (S3 + locking) instead of the CD workflow’s cached state.
- Webhook-driven pipeline resume instead of long polling in CI.
- Idempotency and handling of `ASSIGN`, `UNASSIGN`, and `DELETE` agent access actions.
- Your organization’s secrets management and least-privilege IAM boundaries.

## Out of scope

- Runtime / invoke-time authorization gateways
- Non-AWS agent platforms (pattern is the same; provisioning steps differ)
- Kubernetes agent discovery
