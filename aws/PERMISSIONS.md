# IAM policy for Terraform (AWS Bedrock)

Terraform apply and destroy in this reference require the JSON policy in
[`bedrock-agent-lifecycle-iam-policy.json`](./bedrock-agent-lifecycle-iam-policy.json).

## Apply in AWS

**Replace the entire inline or customer-managed policy** on your Terraform IAM user or role — do not
merge actions one at a time. Partial updates cause repeated `AccessDenied` on
apply/destroy.

```bash
# Example: attach as customer-managed policy (replace ACCOUNT_ID and IAM user name)
aws iam create-policy \
  --policy-name BalkanIDAgentLifecycleTerraform \
  --policy-document file://aws/bedrock-agent-lifecycle-iam-policy.json

aws iam attach-user-policy \
  --user-name YOUR_TERRAFORM_IAM_USER \
  --policy-arn arn:aws:iam::ACCOUNT_ID:policy/BalkanIDAgentLifecycleTerraform
```

Or paste the JSON into an inline policy in the IAM console.

## What each statement covers

| Statement | Terraform / scripts |
|---|---|
| `BedrockAgentsClassic` | `aws_bedrockagent_agent` apply/destroy/refresh (`AGENT_BACKEND=classic`) |
| `BedrockAgentCoreHarnessLifecycle` | `aws_bedrockagentcore_harness` + runtime/memory/endpoints/workload identity create/destroy; pre-apply harness cleanup |
| `IamListRolesForReconciliation` | Pre-apply cleanup: detect IAM role name conflicts outside `/balkanid-agent-lifecycle/` |
| `IamRolesUnderLifecyclePath` | `aws_iam_role` + `aws_iam_role_policy` under `/balkanid-agent-lifecycle/` — scoped via resource ARN `role/balkanid-agent-lifecycle/*` |
| `IamInstanceProfilesForRoleDelete` | `DeleteRole` pre-check: detach role from instance profiles if present |
| `PassExecutionRolesToBedrock` | Pass execution role to `bedrock.amazonaws.com` / `bedrock-agentcore.amazonaws.com` on harness/agent create |
| `CallerIdentity` | Resolves AWS account id for IAM trust policies |

## Not included

AgentCore CLI/CDK deploy (ECR, CloudFormation, VPC, Gateway, etc.), harness invoke,
and `PassCapacityProvider` (Instances compute type only).

## Other AWS stacks in this repository

Each stack has its own least-privilege provisioner policy, scoped to its own IAM path. Attach only
the one(s) for the flows you run, to separate principals where you can.

| Policy | Stack | Scope |
|---|---|---|
| [`bedrock-agent-lifecycle-iam-policy.json`](./bedrock-agent-lifecycle-iam-policy.json) | `terraform/bedrock` (CI gate demo) | Roles under `/balkanid-agent-lifecycle/`, AgentCore harness / Classic agent |
| [`bedrock-guardrails-provisioner-iam-policy.json`](./bedrock-guardrails-provisioner-iam-policy.json) | `terraform/bedrock-guardrails`, `terraform/grant-policies` (default `iam_path`) | Roles and policies under `/balkanid-agents/`; roles can only be created with an `agent-boundary-*` permissions boundary |
| [`kiro-agent-provisioner-iam-policy.json`](./kiro-agent-provisioner-iam-policy.json) | `terraform/agent-role`, `terraform/grant-policies` with `iam_path = "/balkanid-kiro-agents/"` | Roles and policies under `/balkanid-kiro-agents/`; roles only with a `kiro-agent-boundary-*` boundary |

Microsoft Copilot Studio permissions (Entra, Graph, Power Platform) are in [`azure/PERMISSIONS.md`](../azure/PERMISSIONS.md).
