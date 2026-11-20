terraform {
  required_version = ">= 1.5.0"

  required_providers {
    powerplatform = {
      source  = "microsoft/power-platform"
      version = ">= 4.2.0, < 5.0.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# Service principal auth. The SPN must first be registered with Power Platform -
# either powerplatform_admin_management_application, or PowerShell:
#   New-PowerAppManagementApp -ApplicationId <client_id>
provider "powerplatform" {
  tenant_id     = var.tenant_id
  client_id     = var.client_id
  client_secret = var.client_secret
}
