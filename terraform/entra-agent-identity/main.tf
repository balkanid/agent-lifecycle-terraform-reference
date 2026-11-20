# The agent's identity in Entra.
#
# Terraform coverage note:
#
#   Entra Agent ID (the `agentIdentityBlueprint` application type and its `agentIdentity`
#   service principals) has NO Terraform provider support as of September 2026. The
#   hashicorp/azuread provider has no agent_identity resource, and the blueprint is
#   created by POSTing to /applications with an @odata.type discriminator that
#   azuread_application cannot emit.
#
# So this module manages the classic app registration path, which is what Terraform can
# actually do today, and which pre-May-2026 Copilot Studio agents use.
#
# Copilot Studio agents created from May 2026 are issued an Entra Agent ID automatically
# by the platform. For those, do not create an identity here - run the identity gate for
# review, then reconcile the platform-issued identity through the BalkanID Entra
# integration. See docs/copilot/AGENT_IDENTITY.md.

data "azuread_client_config" "current" {}

data "azuread_application_published_app_ids" "well_known" {}

resource "azuread_service_principal" "msgraph" {
  count        = length(var.graph_application_permissions) > 0 ? 1 : 0
  client_id    = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]
  use_existing = true
}

locals {
  owners = length(var.owner_object_ids) > 0 ? var.owner_object_ids : [data.azuread_client_config.current.object_id]

  # Resolve requested permission values to Graph app role ids.
  graph_role_ids = length(var.graph_application_permissions) > 0 ? {
    for name in var.graph_application_permissions :
    name => azuread_service_principal.msgraph[0].app_role_ids[name]
  } : {}
}

resource "azuread_application" "agent" {
  display_name     = var.agent_name
  owners           = local.owners
  sign_in_audience = var.sign_in_audience

  description = "Copilot agent identity, created after BalkanID approval"

  dynamic "required_resource_access" {
    for_each = length(local.graph_role_ids) > 0 ? [1] : []

    content {
      resource_app_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]

      dynamic "resource_access" {
        for_each = local.graph_role_ids

        content {
          id   = resource_access.value
          type = "Role"
        }
      }
    }
  }
}

resource "azuread_service_principal" "agent" {
  client_id                    = azuread_application.agent.client_id
  owners                       = local.owners
  app_role_assignment_required = false

  description = "Copilot agent identity"
}

# Admin consent for each requested Graph permission. This is the step that actually
# grants the blast radius the approver signed off on.
resource "azuread_app_role_assignment" "graph" {
  for_each = local.graph_role_ids

  app_role_id         = each.value
  principal_object_id = azuread_service_principal.agent.object_id
  resource_object_id  = azuread_service_principal.msgraph[0].object_id
}

resource "azuread_application_password" "agent" {
  count = var.create_client_secret ? 1 : 0

  application_id    = azuread_application.agent.id
  display_name      = "terraform-managed"
  end_date_relative = var.secret_end_date_relative
}
