# CD workflow secrets

Configure these on the GitHub **`agent-lifecycle`** [environment](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment) (Settings → Environments → New environment).

Repository secrets work too if you skip creating the environment; the workflow references `environment: agent-lifecycle`.

## Required (all runs)

| Secret | Description |
|---|---|
| `BALKANID_PUBLIC_API_URL` | Public API base URL, e.g. `https://your-tenant.balkanid.app/api/public` |
| `BALKANID_API_KEY_ID` | Employee API key id |
| `BALKANID_API_KEY_SECRET` | Employee API key secret |
| `BALKANID_EMPLOYEE_EMAIL` | Employee the access request is filed for |
| `BALKANID_INTEGRATION_ID` | Integration id for `entityFilterGrant` |

## Required when `enable_bedrock=true`

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM user/role with `aws/bedrock-agent-lifecycle-iam-policy.json` |
| `AWS_SECRET_ACCESS_KEY` | Matching secret |

Bedrock Agents and model access must be enabled in **us-east-1** for the target account.

## Demo flow

1. Actions → **CD** → Run workflow → `apply`, `enable_bedrock=false` (gate-only first).
2. Job logs show `creating access request` then poll lines — **approve or deny in BalkanID**.
3. On approve, apply completes (gate-only: no AWS resources; with Bedrock: IAM role + agent).
4. On deny, the job fails and **no AWS resources are created**.
5. If nobody approves within **`approval_wait_minutes`**, the gate times out — same as deny (fail closed, no AWS).
6. Run workflow → `destroy` to tear down AWS resources from a prior Bedrock apply (uses cached Terraform state).

State is cached per `agent_name` + branch in GitHub Actions cache (PoV-grade; use an S3 backend for production).
