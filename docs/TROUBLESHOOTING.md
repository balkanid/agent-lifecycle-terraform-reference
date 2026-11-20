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
| Gate exits 1 after "partially approved" | The approver granted less than was requested | Raise a new request for the scope you need; partial approval never provisions |
| Gate exits 2 | Approval window elapsed with no decision | Approve in BalkanID and re-run (or raise `APPROVAL_WAIT_MINUTES` / `POLL_TIMEOUT_SECONDS`) |
| Gate exits 3 | Public API unreachable after retries | Check `BALKANID_PUBLIC_API_URL`, network egress and API key; nothing was provisioned |
| `invalid LIFECYCLE_TARGET` | Typo, or a value left in `.env` from another flow | Use `bedrock`, `bedrock-guardrails` or `copilot` (or unset it for the CI gate) |

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

## AWS developer-agent guardrails (`scripts/lifecycle.sh`)

| Symptom | Cause | Fix |
|---|---|---|
| `policy_check.py` denies with "too broad" | A denied managed policy in `AGENT_POLICY_NAMES` | Request a scoped policy; extend `denied_policies` only deliberately |
| "reusing execution role ... is not allowed" | `EXISTING_EXECUTION_ROLE_ARN` is set | Leave it empty; the flow creates the agent's own role |
| `NoSuchEntity` for `agent-boundary-<parent>` | Applying a subagent before its parent exists | Apply the parent first |
| Sensitive grant: "timed out resolving identity" | BalkanID has not discovered the role yet | Run `scripts/trigger_sync.py`, wait for the sync, retry |
| Sensitive grant approved, AWS still denies | Policy not yet attached, outside the boundary, or the resource is not in `secret_arns` / `ssm_parameter_arns` | Re-run with `--wait-provisioning`; keep grant services inside `allowed_services`; list the resource in `terraform/grant-policies` |
| Reaper destroyed an agent unexpectedly | Its expiry passed, its parent expired, or the expiry tag was removed | Re-apply with a new TTL; do not edit tags by hand |
| Reaper never runs | `REAPER_ENABLED` is not `true` as a repository variable | Set it once the `bedrock-guardrails` environment and remote backend are configured |
| `AccessDenied` creating roles or policies | Terraform principal policy out of date | Replace it with `aws/bedrock-guardrails-provisioner-iam-policy.json` in full |

## Microsoft Copilot Studio

See [copilot/TROUBLESHOOTING.md](copilot/TROUBLESHOOTING.md).
