# Nomos — Azure federation bootstrap module.
#
# Creates everything an Azure tenant needs to trust the Nomos OIDC issuer:
#   - App Registration + Service Principal
#   - Federated identity credential (issuer = id.auto-nomos.com)
#   - Role assignment (Reader by default; narrow scope via vars)
#
# Outputs feed the Nomos dashboard cloud-account form.
#
# Final home: github.com/auto-nomos/terraform-azurerm-nomos-bootstrap
# This monorepo copy is the source of truth during M1; we publish to the
# public repo once M1 lands on main.

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

variable "nomos_oidc_issuer" {
  description = "Public URL of the Nomos OIDC issuer. Pinned via the dashboard wizard."
  type        = string
  default     = "https://id.auto-nomos.com"
}

variable "customer_id" {
  description = "Nomos customer id — appears in the federated cred subject pattern."
  type        = string
}

variable "agent_subject" {
  description = "Federated cred subject. M1 supports one cred per agent (Azure caps flexible FIC at 20/app)."
  type        = string
  default     = "customer/UNUSED/agent/UNUSED"
}

variable "use_flexible_fic" {
  description = "M2 — use flexible federated identity credentials (claims-matching). Required for tenants with >20 agents."
  type        = bool
  default     = false
}

variable "fic_claims_match" {
  description = "When use_flexible_fic=true, the claims-matching expression evaluated against the OIDC token. Default matches any agent under this customer."
  type        = string
  default     = ""
}

variable "subscription_id" {
  description = "Azure subscription id to scope the Reader role to."
  type        = string
}

variable "resource_group_name" {
  description = "Optional RG to narrow role assignment to. Empty = subscription scope."
  type        = string
  default     = ""
}

variable "app_display_name" {
  description = "Display name for the App Registration."
  type        = string
  default     = "nomos-agent-broker"
}

variable "role_definition_name" {
  description = "Built-in role to assign. Reader is sufficient for M1 read-only MVP."
  type        = string
  default     = "Reader"
}

# ----- App Registration + SP -----

resource "azuread_application" "nomos" {
  display_name = var.app_display_name
  description  = "Federated identity for Nomos cloud IAM broker."
}

resource "azuread_service_principal" "nomos" {
  client_id = azuread_application.nomos.client_id
}

# ----- Federated credential -----
#
# Subject format Nomos asserts: customer/{customer_id}/agent/{agent_id}
# Azure cap: 20 federated credentials per app. For M1 we ship one
# per agent; M2 swaps to flexible federated identity credentials with
# claims pattern matching.

# Subject-pattern federated cred (M1 default). Capped at 20 per app.
resource "azuread_application_federated_identity_credential" "nomos" {
  count          = var.use_flexible_fic ? 0 : 1
  application_id = azuread_application.nomos.id
  display_name   = "nomos-${var.customer_id}"
  description    = "Trusts Nomos OIDC issuer to assert agent identity"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = var.nomos_oidc_issuer
  subject = (
    var.agent_subject == "customer/UNUSED/agent/UNUSED"
    ? "customer/${var.customer_id}/agent/*"
    : var.agent_subject
  )
}

# M2 — flexible federated identity credentials with claims-matching.
# One trust block matches arbitrarily many agents via claim conditions
# instead of fixed subject strings. Required for tenants >20 agents.
#
# Azure provider doesn't yet expose a dedicated FIC resource — we use the
# REST API directly via azapi to set `claimsMatchingExpression`. Customer
# must declare azapi provider in their root module:
#
#   terraform {
#     required_providers {
#       azapi = { source = "Azure/azapi", version = "~> 1.0" }
#     }
#   }
#
# `fic_claims_match` defaults to matching any agent under this customer.
resource "azapi_resource" "nomos_fic" {
  count                    = var.use_flexible_fic ? 1 : 0
  schema_validation_enabled = false
  type                     = "Microsoft.Graph/applications/federatedIdentityCredentials@v1.0"
  name      = "nomos-fic-${var.customer_id}"
  parent_id = "applications/${azuread_application.nomos.object_id}"

  body = jsonencode({
    name      = "nomos-fic-${var.customer_id}"
    issuer    = var.nomos_oidc_issuer
    audiences = ["api://AzureADTokenExchange"]
    claimsMatchingExpression = {
      languageVersion = 1
      value           = var.fic_claims_match == "" ? "claims['nomos']['customer_id'] eq '${var.customer_id}'" : var.fic_claims_match
    }
  })
}

# ----- Role assignment -----

data "azurerm_subscription" "current" {
  subscription_id = var.subscription_id
}

data "azurerm_resource_group" "scope" {
  count = var.resource_group_name == "" ? 0 : 1
  name  = var.resource_group_name
}

locals {
  role_scope = var.resource_group_name == "" ? data.azurerm_subscription.current.id : data.azurerm_resource_group.scope[0].id
}

resource "azurerm_role_assignment" "nomos" {
  scope                = local.role_scope
  role_definition_name = var.role_definition_name
  principal_id         = azuread_service_principal.nomos.object_id
}

# ----- Outputs -----

output "app_object_id" {
  description = "App Registration object id — paste into the Nomos dashboard."
  value       = azuread_application.nomos.object_id
}

output "app_client_id" {
  description = "App Registration client id (application id) — paste into the Nomos dashboard."
  value       = azuread_application.nomos.client_id
}

output "tenant_id" {
  description = "Tenant id — paste into the Nomos dashboard."
  value       = data.azurerm_subscription.current.tenant_id
}

output "subscription_id" {
  description = "Subscription id — paste into the Nomos dashboard."
  value       = var.subscription_id
}

output "role_scope" {
  description = "Scope at which Reader was assigned."
  value       = local.role_scope
}
