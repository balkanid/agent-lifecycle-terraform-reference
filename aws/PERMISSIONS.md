# IAM policy for `bedrock-lifecycle.user`

Terraform CD/local apply and destroy for this PoV require the JSON policy in
[`bedrock-agent-lifecycle-iam-policy.json`](./bedrock-agent-lifecycle-iam-policy.json).

## Apply in AWS (required)

**Replace the entire inline or customer-managed policy** on the IAM user — do not
merge actions one at a time. Partial updates cause repeated `AccessDenied` on
apply/destroy (e.g. `CreateAgentRuntimeEndpoint`, `GetRole`, `ListInstanceProfilesForRole`).

```bash
# Example: attach as customer-managed policy (adjust account id)
aws iam create-policy \
  --policy-name BalkanIDAgentLifecyclePoV \
  --policy-document file://aws/bedrock-agent-lifecycle-iam-policy.json

aws iam attach-user-policy \
  --user-name bedrock-lifecycle.user \
  --policy-arn arn:aws:iam::537488974137:policy/BalkanIDAgentLifecyclePoV
```

Or paste the JSON into the user's inline policy in the IAM console.

## What each statement covers

| Statement | Terraform / scripts |
|---|---|
| `BedrockAgentsClassic` | `aws_bedrockagent_agent` apply/destroy/refresh (`AGENT_BACKEND=classic`) |
| `BedrockAgentCoreHarnessLifecycle` | `aws_bedrockagentcore_harness` + runtime/memory/endpoints/workload identity create/destroy; `cleanup-agentcore-before-apply.sh` harness delete |
| `IamRolesUnderLifecyclePath` | `aws_iam_role` + `aws_iam_role_policy` under `/balkanid-agent-lifecycle/` — scoped via resource ARN `role/balkanid-agent-lifecycle/*` (path is part of the role ARN; there is no `iam:ResourcePath` condition key) |
| `IamInstanceProfilesForRoleDelete` | `DeleteRole` pre-check: detach role from instance profiles if present |
| `PassExecutionRolesToBedrock` | Pass execution role to `bedrock.amazonaws.com` / `bedrock-agentcore.amazonaws.com` on harness/agent create |
| `CallerIdentity` | CD resolves account id |

## Out of scope (not needed for this PoV)

AgentCore CLI/CDK deploy (ECR, CloudFormation, VPC, Gateway, etc.), harness invoke,
and `PassCapacityProvider` (Instances compute type only).
