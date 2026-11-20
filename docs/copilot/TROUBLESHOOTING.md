# Troubleshooting: Microsoft Copilot Studio path

> This path has not been run end-to-end against a live Microsoft tenant; treat it as a reference design and validate in a test tenant first.

Copilot-specific problems. For BalkanID gate errors (missing env, timeouts, HTTP 403,
step-up MFA) see [`../TROUBLESHOOTING.md`](../TROUBLESHOOTING.md).

## Gates

### Identity gate is skipped or fails for an Agent Builder agent

Agent Builder agents have no Entra identity. Set `ENTRA_IDENTITY_GATE=false`.

### `verify_approved_scope.py` reports drift

A variable (agent name, environment id, solution name, Entra display name, or the
Graph permission list) changed between the gate and the provisioning step, or the
identity gate did not run while `ENTRA_GRAPH_PERMISSIONS` is set. Re-run the gates for the
current configuration. Exit 2 means no approval record exists: run the gates first.

## Power Platform

### `pac` auth fails during `terraform apply`

The service principal is not registered as a Power Platform management application.
There is no portal or az CLI equivalent:

```powershell
New-PowerAppManagementApp -ApplicationId <client_id>
```

### Solution import fails with a component error

Usually one of:

- A custom connector the solution depends on has not been imported yet. Connectors
  first, then connection references, then the agent.
- A connection reference in the package is not bound.
  `powerplatform_managed_solution.connection_references` must bind every reference the
  package declares, not only the ones you use.
- The solution version is lower than the one already installed. Import is rejected
  before it starts.

### Import fails with "managed solution required"

`pac copilot pack` produces an unmanaged solution, and `powerplatform_managed_solution`
only accepts managed. Import the unmanaged solution into a Dataverse environment, then
`pac solution export --managed true`. See [`SETUP.md`](SETUP.md#5-package-the-agent).

### No agent was created and apply succeeded

`SOLUTION_ZIP_PATH` is empty or the file does not exist, so the import resource count is
0. Point it at the managed `.zip`; in CI make sure a step puts the file there before apply.

### Solution export fails and gives no useful reason

A solution containing an agent whose topic names contain a `.` cannot be exported. Rename
the topic.

### The agent imported but does not respond

It was not published. An imported agent exists in Dataverse but is not live.

```bash
pac copilot publish --bot <schemaname> --environment <environment-id>
```

Or set `PUBLISH_AGENT=true` (and `AGENT_SCHEMA_NAME`) so `scripts/publish_copilot_agent.py`
does it.

### Authentication settings or the agent icon did not survive the import

They do not travel with the solution, and neither does channel configuration. Reconfigure
after import. This is documented Microsoft behaviour, not a pipeline bug.

### `powerplatform_copilot_studio_application_insights` fails in CI

That resource does not support service principal authentication. It is disabled by
default for that reason. Use it from an interactive session or not at all.

### `destroy` finds nothing to destroy in CI

Terraform state is a local file carried in the Actions cache (keys prefixed
`tfstate-copilot-`). If the cache was evicted or the agent name or branch differs from the
apply run, the state is gone. Use a remote backend for anything beyond a trial.
