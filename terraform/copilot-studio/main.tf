# Copilot Studio agent lifecycle - Power Platform stack.
#
# What Terraform can and cannot do here, stated plainly, because it shapes the whole
# design:
#
#   There is NO Terraform resource that creates a Copilot Studio agent.
#
# An agent is a Dataverse `bot` row plus N `botcomponent` rows. It travels between
# environments as a component inside a solution .zip. So the supported IaC path is:
#
#   pac copilot pack  ->  solution .zip  ->  powerplatform_managed_solution  ->  pac copilot publish
#
# That gap is exactly why the approval gate matters. Any maker with an environment can
# create an agent in the Copilot Studio portal in under a minute, with no pipeline, no
# review and no ticket. The gate in ../copilot/main.tf is the control point the platform does
# not provide.

locals {
  environment_id = var.create_environment ? powerplatform_environment.agent[0].id : var.environment_id
}

# --- Environment --------------------------------------------------------------

resource "powerplatform_environment" "agent" {
  count            = var.create_environment ? 1 : 0
  display_name     = var.environment_display_name
  location         = var.environment_location
  environment_type = var.environment_type

  dataverse = {
    language_code     = var.environment_language_code
    currency_code     = var.environment_currency_code
    security_group_id = var.environment_security_group_id
  }
}

# --- Governance guardrails ----------------------------------------------------

# Managed Environment is where the Copilot-specific sharing controls live. Without it,
# a maker can share an agent with the whole tenant.
resource "powerplatform_managed_environment" "agent" {
  count          = var.enable_managed_environment ? 1 : 0
  environment_id = local.environment_id

  # The numeric sharing limits below are only honoured when group sharing is disabled.
  # The provider does not validate the combination, so pairing false with a positive
  # limit fails service-side at apply rather than at plan.
  is_group_sharing_disabled  = var.disable_group_sharing
  limit_sharing_mode         = var.limit_sharing_mode
  max_limit_user_sharing     = var.disable_group_sharing ? var.max_limit_user_sharing : -1
  is_usage_insights_disabled = false
  solution_checker_mode      = var.solution_checker_mode
  suppress_validation_emails = true

  copilot_limit_sharing_mode     = var.copilot_limit_sharing_mode
  copilot_max_limit_user_sharing = var.disable_group_sharing ? var.copilot_max_limit_user_sharing : -1
}

# Transcript recording turns agent conversations into reviewable evidence. An access
# review is far more useful when the reviewer can see what the agent actually did.
resource "powerplatform_environment_settings" "agent" {
  environment_id = local.environment_id

  product = {
    features = {
      enable_transcript_recording_for_copilot_studio          = var.enable_transcript_recording
      enable_access_to_session_transcripts_for_copilot_studio = var.enable_transcript_recording
    }
  }
}

# --- Agent identity in the environment ----------------------------------------

# Grants the agent's Entra identity administrative access to this environment, so the
# identity that BalkanID approved is the identity that actually operates here.
resource "powerplatform_environment_application_admin" "agent_identity" {
  count          = var.agent_application_id == "" ? 0 : 1
  environment_id = local.environment_id
  application_id = var.agent_application_id
}

# --- The agent itself, as a solution component --------------------------------

resource "powerplatform_managed_solution" "agent" {
  count          = var.import_solution && var.solution_zip_path != "" ? 1 : 0
  environment_id = local.environment_id
  unique_name    = var.solution_unique_name
  version        = var.solution_version

  source = {
    path = var.solution_zip_path
  }

  connection_references = var.connection_references

  depends_on = [
    powerplatform_managed_environment.agent,
    powerplatform_environment_application_admin.agent_identity,
  ]
}

resource "powerplatform_environment_variable_value" "agent" {
  for_each = var.environment_variables

  environment_id = local.environment_id
  schema_name    = each.key
  value          = each.value

  depends_on = [powerplatform_managed_solution.agent]
}

# --- Publish ------------------------------------------------------------------

# An imported agent exists but is not live. The provider has no publish resource, so
# this shells out to the supported CLI command.
resource "null_resource" "publish" {
  count = var.publish_agent && var.agent_schema_name != "" ? 1 : 0

  triggers = {
    solution_version = var.solution_version
    schema_name      = var.agent_schema_name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command     = "python3 \"${path.module}/../../scripts/publish_copilot_agent.py\""

    environment = {
      PAC_CLI                       = var.pac_cli
      AZURE_TENANT_ID               = var.tenant_id
      AZURE_CLIENT_ID               = var.client_id
      AZURE_CLIENT_SECRET           = var.client_secret
      POWER_PLATFORM_ENVIRONMENT_ID = local.environment_id
      AGENT_SCHEMA_NAME             = var.agent_schema_name
    }
  }

  depends_on = [powerplatform_managed_solution.agent]
}

# --- Telemetry (preview, opt-in) ----------------------------------------------

# Disabled unless a connection string is supplied. See the variable's description:
# this resource does not support service principal auth.
resource "powerplatform_copilot_studio_application_insights" "agent" {
  count                                  = var.application_insights_connection_string != "" && var.agent_bot_id != "" ? 1 : 0
  environment_id                         = local.environment_id
  bot_id                                 = var.agent_bot_id
  application_insights_connection_string = var.application_insights_connection_string

  depends_on = [powerplatform_managed_solution.agent]
}
