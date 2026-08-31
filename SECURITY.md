# Security

## Reporting vulnerabilities

If you believe you found a security issue in this reference repository, contact BalkanID through your account team or [BalkanID support](https://balkan.id/contact). Do not open public GitHub issues for credential leaks or tenant-specific findings.

## What this repo stores

| Location | Contains | Notes |
|---|---|---|
| Git repository | Sample code, IAM policy template, docs | No credentials at `HEAD` |
| GitHub Actions **secrets** | API keys, AWS keys, optional tenant metadata | Never committed; not available to forks |
| GitHub Actions **variables** | Non-secret defaults (URLs, agent names) | Visible in workflow logs if echoed |
| Actions **cache** | Terraform state for CD runs | Private to the repo; includes AWS resource ids |
| Local `.env` | Your credentials | Gitignored — never commit |

## GitHub Actions hardening (built in)

- **CD is manual only** (`workflow_dispatch`) — not triggered on pull requests from forks.
- **Secrets** (`BALKANID_API_KEY_*`, `AWS_*`) are masked in logs when GitHub detects them.
- **`gate.py` / `trigger_sync.py`** redact tenant URLs, owner email, and integration ids when `GITHUB_ACTIONS=true`.
- **GraphQL and API error bodies** are suppressed in CI to avoid leaking tenant details.
- **Terraform outputs** (ARNs, harness ids) are not printed to CD logs.
- **CI** runs TruffleHog (`--only-verified`) on every push/PR and fails if `.env` or tfstate files are tracked.

## Recommended GitHub setup

1. **Environment protection** — On the `agent-lifecycle` environment, require reviewers before CD runs that use production credentials.
2. **Prefer secrets for tenant metadata** — Store these as environment **secrets** (not variables) if you do not want them in logs:
   - `BALKANID_PUBLIC_API_URL`
   - `BALKANID_AGENT_OWNER_EMAIL`
   - `BALKANID_INTEGRATION_ID`
   
   The CD workflow accepts either secrets or variables (secrets take precedence).

3. **Least privilege** — Scope the AWS IAM user to [`aws/bedrock-agent-lifecycle-iam-policy.json`](aws/bedrock-agent-lifecycle-iam-policy.json) and rotate keys periodically.

4. **Forks** — Forks do not inherit your secrets. Third-party pull requests only run CI (no credentials).

## Local development

- Copy `env.example` to `.env` and keep it out of git.
- Do not commit `terraform.tfstate`, `*.tfvars`, or AWS credential files.
- Run with `TF_LOG=ERROR` unless actively debugging Terraform provider traffic.

## Git history

Older commits (before the public release) may contain example AWS account ids or internal hostnames in documentation. Current `main` does not. If you forked before sanitization, prefer cloning fresh from `main`. No API keys or integration ids were found in repository history.

If BalkanID-internal credentials were ever used with this repo's CD workflow, rotate those API keys and AWS access keys after making the repository public.
