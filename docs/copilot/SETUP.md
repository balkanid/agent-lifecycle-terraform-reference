# Setting up the Microsoft Copilot Studio path

> This path has not been run end-to-end against a live Microsoft tenant; treat it as a reference design and validate in a test tenant first.

This path gates a Copilot Studio agent behind a BalkanID approval, then provisions it
with Terraform and the Power Platform CLI. The approval gates alone need no Microsoft
credentials, so you can try those first (section 6).

The prerequisite that takes time is a tenant with Copilot Studio licensing, a Dataverse
environment, and enough permission to create app registrations. A personal Microsoft
account is not sufficient.

Layout used below:

| Path | Role |
|---|---|
| `terraform/copilot` | Gate-only root module |
| `terraform/copilot-studio` | Power Platform stack: guardrails, solution import, publish |
| `terraform/entra-agent-identity` | Optional: the agent's Entra app registration |
| `scripts/copilot-local.sh` | Local wrapper: gates, scope check, apply, destroy |
| `.github/workflows/copilot-cd.yml` | Manual-dispatch pipeline running the same flow |

## 1. A tenant

Use a non-production tenant with Copilot licensing. The
[Microsoft 365 Developer Program](https://developer.microsoft.com/microsoft-365/dev-program)
offers sandbox tenants; eligibility and terms change, so check the current requirements.
Copilot Studio is a separate license: start its trial from
[copilotstudio.microsoft.com](https://copilotstudio.microsoft.com) inside that tenant.

You need, in the tenant:

- Power Platform Administrator (plus AI Administrator if you will review agent identities)
- A Power Platform environment with Dataverse provisioned
- Copilot Studio enabled in that environment

## 2. Tooling

```bash
# .NET SDK, Python 3.11+, Terraform 1.5+, Azure CLI: install with your package manager.
dotnet tool install --global Microsoft.PowerApps.CLI.Tool
export PATH="$PATH:$HOME/.dotnet/tools"
pac --version

az login --tenant <tenant-id>
pac auth create --name eval --environment https://contoso.crm.dynamics.com
pac org list
```

If `pac org list` returns your environment, the Copilot Studio path will work.

## 3. The service principal

Terraform needs a service principal, and Power Platform will not accept an ordinary one.
It has to be registered as a management application first, a PowerShell step with no
portal or az CLI equivalent.

```bash
az ad app create --display-name copilot-agent-lifecycle
az ad sp create --id <app-id>
az ad app credential reset --id <app-id> --years 1
```

Then, from PowerShell:

```powershell
Install-Module -Name Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser
Add-PowerAppsAccount
New-PowerAppManagementApp -ApplicationId <app-id>
```

Only if you will run `terraform/entra-agent-identity`, grant and admin-consent the Graph
permissions in [`azure/PERMISSIONS.md`](../../azure/PERMISSIONS.md):

```bash
az ad app permission add --id <app-id> \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions 18a4783c-866b-4cc7-a460-3d5e5662c884=Role 06b708a9-e830-4db3-a914-8e69da51d44f=Role
az ad app permission admin-consent --id <app-id>
```

Finally, add the service principal as a Dataverse application user in the target
environment (Power Platform admin center, Environments, your environment, Settings,
Users and permissions, Application users, New app user). Give it the narrowest security
role that lets it import solutions and publish agents; avoid System Administrator
outside a throwaway test environment.

## 4. Configure

```bash
cp env.example .env
# Fill in the Copilot Studio section: AZURE_*, POWER_PLATFORM_ENVIRONMENT_ID,
# SOLUTION_ZIP_PATH, AGENT_SCHEMA_NAME, and the BalkanID API settings.
set -a && source .env && set +a
LIFECYCLE_TARGET=copilot python3 scripts/preflight.py
```

Never commit `.env`. In CI, keep secrets in the `copilot-agent-lifecycle` GitHub
environment; see `.github/CD_CONFIG.md`.

## 5. Package the agent

### Why the agent is not defined in HCL

A Copilot Studio agent is a Dataverse record: `bot` holds the agent and `botcomponent`
holds its topics, knowledge sources, triggers and settings. Neither has a Terraform
resource. The agent moves between environments inside a solution `.zip`, so the pipeline
is:

```
author in Copilot Studio (or the VS Code extension)
  -> pac copilot clone / pull        agent as YAML in source control
  -> git                             review and approve the change itself
  -> pac copilot pack                build the solution .zip
  -> pac solution check              static analysis
  -> powerplatform_managed_solution  import into the target environment (Terraform)
  -> pac copilot publish             make it live
```

Terraform owns the environment, guardrails, connections and the import. `pac` owns the
agent's content and the publish.

### Get the agent into source control

```bash
pac copilot list --environment $POWER_PLATFORM_ENVIRONMENT_ID
pac copilot clone --bot <schemaname> --output-dir ./agent-src
# or start fresh:
pac copilot init --name "Trial Intake Assistant" --publisher-prefix bkn --project-dir ./agent-src

# after edits
pac copilot pull --project-dir ./agent-src
pac copilot pack --publisher-prefix bkn --solution-name BalkanIDAgentLifecycle \
  --project-dir ./agent-src --output-path ./build/BalkanIDAgentLifecycle.zip
```

### The package is unmanaged; Terraform needs a managed one

`pac copilot pack` produces an unmanaged solution, and `powerplatform_managed_solution`
rejects it ("managed solution required"). There is no offline conversion: import it into
a build environment and export it back as managed.

```bash
pac solution import --path ./build/BalkanIDAgentLifecycle.zip --publish-changes
pac solution export --name BalkanIDAgentLifecycle \
  --path ./build/BalkanIDAgentLifecycle_managed.zip --managed true
pac solution check --path ./build/BalkanIDAgentLifecycle_managed.zip \
  --outputDirectory ./build/checker
```

Point `SOLUTION_ZIP_PATH` at the managed `.zip`. Set `import_solution = false` on
`terraform/copilot-studio` to apply the environment guardrails without importing anything.

### Known export constraints

- Only unmanaged solutions can be exported from the maker portal.
- A solution containing an agent whose topic names contain a `.` cannot be exported.
- Authentication settings, channel configuration and the agent icon do not travel with
  the solution. Reconfigure them after import.
- Custom connectors must be imported before the connection references and the agent.
- An imported agent is not live until it is published.
- More than 250 topics or 100 entities requires the standard harness export path.

Source: [Export and import agents using solutions](https://learn.microsoft.com/en-us/microsoft-copilot-studio/authoring-export-import-bots)

## 6. Run it

Gates only (needs BalkanID credentials, no Microsoft ones):

```bash
./scripts/copilot-local.sh gate
```

The gate blocks until a human approves in BalkanID. Exit codes: 0 approved, 1 denied or
partially approved, 2 approval window elapsed, 3 BalkanID unreachable.

Full flow (gates, scope check, Terraform, optional publish, BalkanID sync):

```bash
ENTRA_IDENTITY_GATE=true PROVISION_AGENT_IDENTITY=true PUBLISH_AGENT=true \
  ./scripts/copilot-local.sh apply-lifecycle
./scripts/copilot-local.sh destroy-lifecycle
```

`scripts/verify_approved_scope.py` runs before any provisioning and fails if the
environment (agent name, environment, solution, Entra display name, Graph permissions)
differs from what was approved.

To run in CI instead, dispatch `.github/workflows/copilot-cd.yml` from the Actions tab.
It uses a GitHub environment named `copilot-agent-lifecycle`; add required reviewers to
it so a destroy or apply needs a second human.

## Known friction

- Dataverse provisioning on a new environment takes 10 to 20 minutes.
- `New-PowerAppManagementApp` has no portal or az CLI equivalent.
- Copilot Studio trial licensing can take an hour to propagate to a new environment. If
  the portal says the feature is unavailable, wait rather than reprovisioning.
- Terraform state here is local (cached in CI). Use a remote backend before relying on
  this beyond a trial.
