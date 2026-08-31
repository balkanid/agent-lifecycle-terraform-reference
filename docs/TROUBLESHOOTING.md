# Troubleshooting CD and local runs

Common failures when running the [CD workflow](../.github/workflows/cd.yml) or `./scripts/terraform-local.sh`.

## Before every CD run

1. **Replace** (do not merge) the IAM policy on `bedrock-lifecycle.user` with [`aws/bedrock-agent-lifecycle-iam-policy.json`](../aws/bedrock-agent-lifecycle-iam-policy.json). Preflight checks `iam:ListRoles`.
2. Use **Actions → CD → Run workflow** (new dispatch), not **Re-run failed jobs**, after pushing fixes.
3. Branch **`EN-8896`** (or your feature branch) must contain the latest commit; CD checks out the branch you select.
4. Set **`AGENT_BACKEND=agentcore`** unless your account is allowlisted for Classic Bedrock Agents.

## BalkanID gates

| Symptom | Cause | Fix |
|---|---|---|
| Gate times out | No approver action in tenant | Approve/deny in BalkanID → Access Requests while the job waits |
| `missing INTEGRATION_ID` | Sync or gate env not set | Set `BALKANID_INTEGRATION_ID` secret/variable on `agent-lifecycle` environment |
| HTTP 520 / 429 on poll | Transient Public API errors | Retry; `balkanid_api.py` retries automatically |

## AgentCore pre-apply reconciliation

| Symptom | Cause | Fix |
|---|---|---|
| IAM role outside `/balkanid-agent-lifecycle/` | Same role name created at `/` (often app provisioning) | Disable app provisioning on the AWS integration; delete conflicting role with IAM admin, or use a new `AGENT_NAME` |
| `iam:GetRole` AccessDenied | Out-of-date IAM policy or SCP | Replace Terraform user policy; see [PERMISSIONS.md](../aws/PERMISSIONS.md) |
| Managed memory cannot be deleted | Harness still READY | Expected — pre-apply skips memory cleanup when harness is healthy |
| Ambiguous `moved` / stale state | Cached state from partial applies | Fixed in branch: pre-apply runs `reconcile-terraform-iam-state.sh` to migrate/purge IAM addresses |

## Terraform apply

| Symptom | Cause | Fix |
|---|---|---|
| `EntityAlreadyExists` on IAM role | Role name taken globally in account | Run **destroy** + AWS sweep, or delete role with admin, or change `AGENT_NAME` |
| Refresh error on `aws_iam_role.execution` | Stale state pointing at unreadable role | Pre-apply purges IAM from state; re-run apply |
| Harness update fails | Execution role missing after partial destroy | Apply recreates role under `/balkanid-agent-lifecycle/` |

## Destroy and cleanup

CD **destroy** runs `terraform destroy` then **`cleanup-after-destroy.sh`** (always, even if Terraform fails). The sweep deletes:

- AgentCore harnesses matching `AGENT_NAME`
- Orphan AgentCore memory (skips harness-managed memory)
- Classic Bedrock agents and aliases
- IAM role under `/balkanid-agent-lifecycle/`

Local equivalent:

```bash
./scripts/terraform-local.sh destroy-lifecycle
# or sweep only:
./scripts/terraform-local.sh cleanup-after-destroy
```

## Demo checklist (Acorns / JIT lifecycle)

1. GitHub env `agent-lifecycle`: `SERVICE_ACCOUNT_GATE=true`, `AGENT_GATE=true`, `PROVISION_AWS_AGENT=true`, `AGENT_BACKEND=agentcore`.
2. **Disable app provisioning** on the demo AWS integration (gates are approval-only; Terraform creates IAM).
3. Update IAM policy in AWS account `537488974137` (or your target account).
4. CD → apply → approve service account request → approve agent access request.
5. After demo: CD → destroy to tear down AWS resources.

## Still stuck?

Reset from a clean slate:

1. CD → **destroy** on the same `AGENT_NAME`.
2. Confirm harness, memory, and IAM role are gone in AWS console (account + region for Bedrock; IAM is global).
3. CD → **apply** with a **new workflow dispatch** on the latest branch commit.
