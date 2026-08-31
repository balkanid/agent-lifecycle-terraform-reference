# Security

## Reporting security issues

Per the [BalkanID Trust Center](https://trustcenter.balkan.id/), report security questions, incidents, or concerns to **[security@balkan.id](mailto:security@balkan.id)**.

When reporting a finding related to **this reference repository** (sample code, docs, or GitHub Actions workflows):

1. Email **security@balkan.id** with a description, reproduction steps, and impact.
2. Do **not** open a public GitHub issue for credential leaks, tenant-specific data, or exploitable vulnerabilities.
3. Do **not** test against BalkanID production systems or customer tenants without authorization.
4. Allow reasonable time for triage before public disclosure.

For non-security bugs or documentation fixes, use [GitHub Issues](https://github.com/balkanid/agent-lifecycle-terraform-reference/issues).

## Protecting your credentials

When you run this reference in your own GitHub repository or locally:

| Location | Guidance |
|---|---|
| Git | Never commit `.env`, `*.tfvars`, or `terraform.tfstate` |
| GitHub Actions **secrets** | API keys, AWS keys, tenant URL, owner email, integration id |
| GitHub Actions **variables** | Non-sensitive toggles (region, agent name, timeouts) |
| Actions **cache** | CD stores Terraform state in your repo's cache — use a remote backend for production |

## GitHub Actions setup

1. Create environment **`agent-lifecycle`** and add secrets per [`.github/CD_CONFIG.md`](.github/CD_CONFIG.md).
2. Store `BALKANID_PUBLIC_API_URL`, `BALKANID_AGENT_OWNER_EMAIL`, and `BALKANID_INTEGRATION_ID` as **secrets** (not variables) so GitHub masks them in logs.
3. Require reviewers on the environment when runs use production credentials.
4. Scope the AWS IAM principal to [`aws/bedrock-agent-lifecycle-iam-policy.json`](aws/bedrock-agent-lifecycle-iam-policy.json) and rotate keys periodically.

The sample CD workflow runs on **`workflow_dispatch`** only. Forks do not inherit your secrets.

## Local development

- Copy `env.example` to `.env` and keep it gitignored.
- Use `TF_LOG=ERROR` unless you are debugging Terraform provider traffic.
