# Permissions (Microsoft Copilot Studio path)

> This path has not been run end-to-end against a live Microsoft tenant; treat it as a
> reference design and validate in a test tenant first.

Two permission surfaces, because Microsoft splits Copilot across control planes that do
not share an authorization model. Grant the minimum for the stacks you actually run. If
you only run the approval gates, no Microsoft permissions are needed at all.

## 1. The pipeline service principal (Power Platform)

Used by: `terraform/copilot-studio` and `pac copilot publish`
(`scripts/publish_copilot_agent.py`).

| Requirement | How to grant |
|---|---|
| Registered as a Power Platform management app | `New-PowerAppManagementApp -ApplicationId <client_id>`, or the `powerplatform_admin_management_application` resource |
| Power Platform Administrator or Dynamics 365 Administrator | Entra directory role |
| Dataverse application user in the target environment, with a security role | `powerplatform_environment_application_admin`, or Power Platform admin center, Environment, S2S apps |

Known gap: `powerplatform_copilot_studio_application_insights` does not support service
principal auth, so it stays disabled by default. Use an interactive `az login` session
if you need it.

## 2. The pipeline service principal (Microsoft Graph)

Only needed for `terraform/entra-agent-identity`. Application permissions,
admin-consented (see `copilot-agent-lifecycle-graph-permissions.json`):

| Permission | Needed for |
|---|---|
| `Application.ReadWrite.OwnedBy` | creates the agent's app registration and manages only the registrations the pipeline owns (the module always keeps the pipeline an owner). Use `Application.ReadWrite.All` only if your tenant blocks this. |
| `AppRoleAssignment.ReadWrite.All` | admin-consenting the agent's own Graph permissions |
| `Application.Read.All` | reading the Microsoft Graph service principal's app roles; Graph requires it together with `AppRoleAssignment.ReadWrite.All` to grant consent |

`AppRoleAssignment.ReadWrite.All` is broad: it can grant any app role. Prefer granting the agent's consent out-of-band by an admin. If your agents get their identity from the platform (see below), do not
grant them to the pipeline: skip `terraform/entra-agent-identity` and set
`PROVISION_AGENT_IDENTITY=false`.

The Graph permissions the *agent* is granted are a separate, reviewable list
(`ENTRA_GRAPH_PERMISSIONS`). Keep it short, prefer `.Selected` scopes, and note that
`scripts/verify_approved_scope.py` refuses to provision permissions that were not part
of the approved request.

## 3. Entra Agent ID: what you cannot automate yet

Copilot Studio agents created from May 2026 are issued an Entra Agent ID automatically
by the platform. That identity is a `servicePrincipal` of subtype Agent, instantiated
from an `agentIdentityBlueprint` application.

There is no Terraform support for either object. `hashicorp/azuread` has no
`azuread_agent_identity` resource, and the blueprint is created by POSTing to
`/applications` with an `@odata.type` discriminator that `azuread_application` cannot
emit. Creating one means calling Graph directly:

```
POST /v1.0/applications/
  { "@odata.type": "Microsoft.Graph.AgentIdentityBlueprint", "displayName": "...",
    "sponsors@odata.bind": [...], "owners@odata.bind": [...] }

POST /beta/serviceprincipals/Microsoft.Graph.AgentIdentity
  { "displayName": "...", "agentIdentityBlueprintId": "..." }
```

Directory roles: AI Reader to view, Agent ID Administrator to manage. Applying
Conditional Access or identity governance to agent identities requires Entra Agent ID
licensing; viewing does not.

This repository manages the classic app registration path instead, which is what
Terraform can do today and what pre-May-2026 agents use. For platform-issued Agent IDs,
run the identity gate for review and reconcile the resulting identity through the
BalkanID Entra integration.

## References

- [Power Platform Terraform provider](https://registry.terraform.io/providers/microsoft/power-platform/latest)
- [Entra Agent ID](https://learn.microsoft.com/en-us/entra/agent-id/agent-identities)
- [Copilot Studio agent identities](https://learn.microsoft.com/en-us/microsoft-copilot-studio/govern-agents-identities-overview)
