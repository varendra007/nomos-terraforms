# Nomos — Azure federation bootstrap module.
#
# Creates everything an Azure tenant needs to trust the Nomos OIDC issuer:
#   - App Registration + Service Principal
#   - Federated identity credentials (one per agent_id)
#   - Role assignment (Reader by default; narrow scope via vars)
#
# IMPORTANT — Azure federated identity credential constraints:
#   - Subject must be an EXACT string. Wildcards are NOT supported.
#   - Flexible FIC (claimsMatchingExpression) is restricted to a small set
#     of Microsoft-trusted issuers (GitHub, Terraform Cloud, etc.) and is
#     blocked for custom OIDC issuers like id.auto-nomos.com.
#   - Hard cap of 20 federated credentials per App Registration.
#
# This module always provisions a FIC for the `verify-poll` agent so the
# /app/cloud "Verify now" probe succeeds. Pass `additional_agent_ids` to
# create one FIC per real agent that will call Azure through Nomos.

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

variable "nomos_oidc_issuer" {
  description = "Public URL of the Nomos OIDC issuer."
  type        = string
  default     = "https://id.auto-nomos.com"
}

variable "customer_id" {
  description = "Nomos customer id — embedded in every federated cred subject."
  type        = string
}

variable "additional_agent_ids" {
  description = <<-EOT
    List of agent_ids that should be allowed to call Azure through this app.
    One federated identity credential is created per id (subject =
    customer/{customer_id}/agent/{agent_id}). The `verify-poll` id is
    always added. Azure caps the total at 20 credentials per app.
  EOT
  type        = list(string)
  default     = []
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
  description = "Built-in role to assign. Reader is sufficient for read-only access."
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

# ----- Federated credentials -----
#
# One FIC per agent_id. `verify-poll` is always included so the dashboard
# "Verify now" button succeeds. Add real agent_ids via `additional_agent_ids`.

locals {
  agent_ids = toset(concat(["verify-poll"], var.additional_agent_ids))
}

resource "azuread_application_federated_identity_credential" "nomos" {
  for_each       = local.agent_ids
  application_id = azuread_application.nomos.id
  display_name   = "nomos-${var.customer_id}-${each.value}"
  description    = "Trusts Nomos OIDC issuer to assert agent identity"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = var.nomos_oidc_issuer
  subject        = "customer/${var.customer_id}/agent/${each.value}"
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

output "agent_ids_with_credentials" {
  description = "All agent_ids that have a federated identity credential on this app."
  value       = sort(tolist(local.agent_ids))
}
