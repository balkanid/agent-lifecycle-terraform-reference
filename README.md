# BalkanID agent lifecycle — Terraform reference

Reference implementation for gating AI agent creation on **BalkanID approval** before Terraform provisions anything, on any platform. Copy the pattern into the IaC and CI you already run; BalkanID decides **who may create agents**, **who owns them**, **what identity they run as** and **what was approved**.

Every target follows the same steps:

```
pipeline (Terraform / CI / script)
    → createRequest: CREATE_SERVICE_ACCOUNT (the agent's own identity)   optional
    → createRequest: AGENT_ACCESS (the agent: owner, purpose, placement)
    → BalkanID policies → approver acts (fail closed on deny, partial approval, timeout, API error)
    → approved → provision the agent and its identity
    → syncIntegration → BalkanID discovers the agent and links it to its owner
    → SERVICE_ACCOUNT_ASSIGNMENT for time-bound sensitive access   optional
```

This is **lifecycle and policy enforcement**, not runtime authorization. When approval completes BalkanID can also call the **`request.actioned` webhook**; this reference polls the Public API, and either works in production.

| Target | What it shows | Status |
|---|---|---|
| [AWS Bedrock CI gate](#aws-bedrock-ci-gate) | CI/CD gates, then Terraform creates the IAM role and AgentCore harness (or Classic agent) | Run live |
| [AWS developer-agent guardrails](#aws-developer-agent-guardrails) | Developer-created agents get their own role, a permissions boundary, an expiry and minutes-long sensitive grants | Tested against a mock API |
| [Microsoft Copilot Studio](#microsoft-copilot-studio) | Gates a Copilot Studio agent and its Entra identity, then imports the solution | **Not run against a live tenant** |
| [Kiro agent role](#kiro-agent-role) | Terraform for the per-agent IAM role a Kiro IDE agent assumes | Used by the Kiro reference |

## Repository layout

```
scripts/                           Standard library only; one shared copy used by every target
  balkanid_api.py                  Public API client: retries, polling, fail-closed outcomes, log redaction
  gate.py                          AGENT_ACCESS gate (LIFECYCLE_TARGET picks the payload)
  service_account_gate.py          CREATE_SERVICE_ACCOUNT gate for the agent's AWS role
  preflight.py, trigger_sync.py, verify_imports.py
  terraform-local.sh, cleanup-*.sh, reconcile-*.sh     AWS Bedrock CI gate (local runs, AgentCore cleanup)
  lifecycle.sh, policy_check.py, request_sensitive_access.py, reap_expired.py   developer-agent guardrails
  entra_agent_identity_gate.py, verify_approved_scope.py, publish_copilot_agent.py, copilot-local.sh   Copilot
terraform/
  main.tf ...                      Gate-only root (AWS Bedrock CI gate)
  bedrock/                         IAM role + AgentCore harness or Classic agent
  bedrock-guardrails/              Developer agent: own role, permissions boundary, harness (workspace per agent)
  grant-policies/                  Time-bound sensitive grant policies (iam_path selects Bedrock or Kiro)
  agent-role/                      Kiro agent IAM role
  copilot/                         Gate-only root (Copilot)
  copilot-studio/, entra-agent-identity/   Copilot Studio solution + guardrails, Entra app registration
policies/                          Guardrail rules and matching BalkanID request policies
aws/, azure/                       Least-privilege provisioner policies and permission guides
docs/                              TROUBLESHOOTING.md, BEDROCK_GUARDRAILS.md, copilot/
tests/                             Unit and end-to-end tests against a mock BalkanID API
.github/workflows/                 ci.yml, cd.yml (Bedrock CI gate), bedrock-guardrails*.yml, copilot-cd.yml
```

## Prerequisites

- BalkanID: agent access requests enabled on your tenant, a connected integration for the target platform (`INTEGRATION_ID`), an employee API key that can call `createRequest`, `requests`, `identities` and `syncIntegration` on the [Public API](https://docs.balkan.id/), and request policies for your organization.
- Python 3.10+ (no pip install) and Terraform 1.5+ (1.7+ for `terraform/entra-agent-identity`). Platform credentials only when you provision.
- `cp env.example .env` and fill in the BalkanID section. Scripts read `.env`; real environment variables win.

## AWS Bedrock CI gate

The CI/CD flow that gates an AWS Bedrock agent: `service_account_gate.py` and `gate.py` in GitHub Actions or locally, then `terraform/bedrock`, then `syncIntegration`.

**AWS (only when provisioning):** Bedrock in your region ([AgentCore regions](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-regions.html)), model access (default Amazon Nova Micro), and [`aws/bedrock-agent-lifecycle-iam-policy.json`](aws/bedrock-agent-lifecycle-iam-policy.json). New accounts use `AGENT_BACKEND=agentcore`; Classic Bedrock Agents are in [maintenance mode](https://docs.aws.amazon.com/bedrock/latest/userguide/agents-classic-maintenance-mode.html).

### Quick start — gate only (no AWS)

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

   Exit code `0` = approved, `1` = denied or partially approved, `2` = no decision in time, `3` = Public API unreachable.

3. Approve or deny the request in BalkanID while the script runs.

### Terraform

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

#### Two-gate flow (service account + agent)

Approval gates for service-role create and agent access; **Terraform provisions all AWS resources** after approvals:

```bash
./scripts/terraform-local.sh apply-lifecycle
```

This runs `service_account_gate.py` then `gate.py`, then Terraform.

Teardown (Terraform destroy + AWS orphan sweep):

```bash
./scripts/terraform-local.sh destroy-lifecycle
```

In GitHub CD, set `SERVICE_ACCOUNT_GATE=true` and `AGENT_GATE=true` with `PROVISION_AWS_AGENT=true`. Configure `POLL_SECONDS` for poll interval (default 5). See [`.github/CD_CONFIG.md`](.github/CD_CONFIG.md) and [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

#### Teardown and re-runs (AgentCore)

```bash
./scripts/terraform-local.sh destroy-lifecycle   # destroy + AWS sweep
./scripts/terraform-local.sh apply-lifecycle       # gates + apply + sync
```

`destroy-lifecycle` and CD **destroy** run `cleanup-after-destroy.sh` after Terraform to remove lingering harnesses, Classic agents, memory, and the lifecycle-path IAM role.

Pre-apply reconciliation (`cleanup-agentcore-before-apply.sh`) runs before AgentCore apply when reusing the same `AGENT_NAME`. Alternatively, use a fresh agent name each run.

See [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) for common CD failures.

#### Variables

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

### CI / CD (GitHub Actions)

#### CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) validates Python, Terraform, and IAM policy JSON on every push/PR.

#### CD

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

### AWS IAM policy

Attach [`aws/bedrock-agent-lifecycle-iam-policy.json`](aws/bedrock-agent-lifecycle-iam-policy.json) to the IAM user or role that runs Terraform. **Replace the entire policy in AWS** (do not merge actions incrementally) — see [`aws/PERMISSIONS.md`](aws/PERMISSIONS.md). IAM role management is scoped to path `/balkanid-agent-lifecycle/`.

## AWS developer-agent guardrails

For developers who create Bedrock AgentCore agents themselves. Without guardrails the agent runs as its creator; here every agent gets its own approved role `agent-<name>` under a permissions boundary, a named owner and an expiry, and reaches secrets, production or customer data only through minutes-long grants approved with step-up MFA.

```
scripts/lifecycle.sh apply dev-assistant      policy_check → CREATE_SERVICE_ACCOUNT → AGENT_ACCESS → terraform → sync
scripts/lifecycle.sh grant dev-assistant BalkanIDAgentSecretsRead 30 "rotate staging creds"   SERVICE_ACCOUNT_ASSIGNMENT
scripts/lifecycle.sh destroy dev-assistant    terraform destroy → sync
bedrock-guardrails-reaper.yml (hourly, opt-in)   destroy expired agents, children first
```

It uses `terraform/bedrock-guardrails` (one Terraform workspace per agent, remote backend recommended) and `terraform/grant-policies`, separate from the CI gate's `terraform/bedrock` and its cached state. Setup, design and threat model: [docs/BEDROCK_GUARDRAILS.md](docs/BEDROCK_GUARDRAILS.md). Request policies and step-up MFA: [policies/BALKANID_POLICIES.md](policies/BALKANID_POLICIES.md).

## Microsoft Copilot Studio

**This path has not been run end-to-end against a live Microsoft tenant.** Treat it as a reference design and validate it in a test tenant first.

Gates a Copilot Studio agent behind BalkanID approval, then provisions it with Terraform and the Power Platform CLI. Set `LIFECYCLE_TARGET=copilot`. The gates alone need no Microsoft credentials.

- `terraform/copilot`: gate-only root module.
- `terraform/copilot-studio`: Managed Environment guardrails and import of the managed solution that carries the agent.
- `terraform/entra-agent-identity` (optional): the agent's Entra app registration with only the approved Graph permissions, gated by `scripts/entra_agent_identity_gate.py`.
- `scripts/copilot-local.sh` (`gate`, `apply-lifecycle`, `destroy-lifecycle`) and `.github/workflows/copilot-cd.yml` (manual dispatch, environment `copilot-agent-lifecycle`).
- `scripts/verify_approved_scope.py` fails the run if the configuration drifted from what was approved.

Limits: no Terraform resource creates a Copilot Studio agent (it ships as a managed solution `.zip`), and Entra Agent ID has no Terraform support. See [docs/copilot/SETUP.md](docs/copilot/SETUP.md), [ARCHITECTURE.md](docs/copilot/ARCHITECTURE.md), [AGENT_IDENTITY.md](docs/copilot/AGENT_IDENTITY.md), [TROUBLESHOOTING.md](docs/copilot/TROUBLESHOOTING.md) and [azure/PERMISSIONS.md](azure/PERMISSIONS.md).

## Kiro agent role

The IDE side (Kiro agent configs, hooks, registration, short-lived credentials) lives in [agent-lifecycle-kiro-reference](https://github.com/balkanid/agent-lifecycle-kiro-reference). It uses two modules from this repository:

```bash
terraform -chdir=terraform/grant-policies apply -var='iam_path=/balkanid-kiro-agents/' \
  -var='secret_arns=["arn:aws:secretsmanager:us-east-1:123456789012:secret:staging/*"]'   # once per account
terraform -chdir=terraform/agent-role apply -var=agent_name=infra-helper \
  -var='developer_principal_arns=["arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_Developer_0123456789abcdef"]'
```

Run them with a principal that has [`aws/kiro-agent-provisioner-iam-policy.json`](aws/kiro-agent-provisioner-iam-policy.json).

## Shared scripts

`gate.py`, `service_account_gate.py` and `preflight.py` serve every target; `LIFECYCLE_TARGET` (`bedrock` by default, `bedrock-guardrails`, `copilot`) selects the payload and checks. Gates exit `0` approved, `1` denied, partially approved or request failed, `2` no decision before the timeout, `3` Public API unreachable. Every outcome but `0` stops the pipeline. In CI (`CI` or `GITHUB_ACTIONS` set) owner emails, tenant URLs and GraphQL error details are redacted from logs; API keys are never logged.

## BalkanID Public API usage

| API | Used by |
|---|---|
| `createRequest` `AGENT_ACCESS` | `gate.py`: owner, agent name and type, integration, intended IAM role or Copilot placement (in `metadata`), expiry for developer agents |
| `createRequest` `CREATE_SERVICE_ACCOUNT` | `service_account_gate.py` (AWS role), `entra_agent_identity_gate.py` (Entra identity). Approval only; Terraform creates the identity |
| `createRequest` `SERVICE_ACCOUNT_ASSIGNMENT` | `request_sensitive_access.py`: time-bound grant with `duration` |
| `requests`, `identities` | Approval polling; resolving an agent role's BalkanID identity |
| `syncIntegration` | `trigger_sync.py` after apply and destroy |

Requests do not send `identityType`; the request type decides it. See the [Public API documentation](https://docs.balkan.id/) for request shapes, authentication and webhooks.

## Testing

```bash
python3 -m unittest discover -s tests -v    # mock BalkanID API, fake terraform and aws binaries
python3 scripts/verify_imports.py
```

## Production considerations

This repository is a **reference**, not a production deployment template. Before adopting it, plan for:

- Remote Terraform state (S3 + locking) instead of the CD workflow’s cached state.
- Webhook-driven pipeline resume instead of long polling in CI.
- Idempotency and handling of `ASSIGN`, `UNASSIGN`, and `DELETE` agent access actions.
- Your organization’s secrets management and least-privilege IAM boundaries.
- GitHub OIDC (`aws-actions/configure-aws-credentials`, `azure/login`) instead of static cloud keys.

## Out of scope

- Runtime / invoke-time authorization gateways
- Kubernetes agent discovery

## Security

See [SECURITY.md](SECURITY.md).
