# Nomos — GCP federation bootstrap module.
#
# Creates a Workload Identity Federation pool + provider trusting Nomos's
# OIDC issuer, plus a Service Account the federated identity impersonates.
#
# Final home: github.com/auto-nomos/terraform-google-nomos-bootstrap.

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "nomos_oidc_issuer" {
  description = "Public URL of the Nomos OIDC issuer."
  type        = string
  default     = "https://id.auto-nomos.com"
}

variable "customer_id" {
  description = "Nomos customer id — appears in the WIF attribute condition."
  type        = string
}

variable "project_id" {
  description = "GCP project id."
  type        = string
}

variable "region" {
  description = "GCP region — informational."
  type        = string
  default     = "us-central1"
}

variable "pool_id" {
  description = "Workload Identity Pool id."
  type        = string
  default     = "nomos-broker-pool"
}

variable "provider_id" {
  description = "Workload Identity Provider id."
  type        = string
  default     = "nomos-broker-provider"
}

variable "service_account_id" {
  description = "Service account the federated identity impersonates."
  type        = string
  default     = "nomos-agent-broker"
}

variable "service_account_roles" {
  description = "Roles granted to the SA. M7 defaults to Viewer at project scope."
  type        = list(string)
  default     = ["roles/viewer"]
}

# ----- WIF pool + provider -----

resource "google_iam_workload_identity_pool" "nomos" {
  workload_identity_pool_id = var.pool_id
  display_name              = "Nomos broker pool"
  description               = "Trusts the Nomos OIDC issuer at id.auto-nomos.com."
}

resource "google_iam_workload_identity_pool_provider" "nomos" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.nomos.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "Nomos OIDC"

  oidc {
    issuer_uri        = var.nomos_oidc_issuer
    allowed_audiences = ["//iam.googleapis.com/${var.nomos_oidc_issuer_audience_prefix}"]
  }

  attribute_mapping = {
    "google.subject"     = "assertion.sub"
    "attribute.customer" = "assertion.nomos.customer_id"
    "attribute.agent"    = "assertion.nomos.agent_id"
  }

  attribute_condition = "attribute.customer == \"${var.customer_id}\""
}

variable "nomos_oidc_issuer_audience_prefix" {
  description = "Prefix for the WIF audience — leave default unless explicitly overriding."
  type        = string
  default     = "projects/_/locations/global/workloadIdentityPools/nomos-broker-pool/providers/nomos-broker-provider"
}

# ----- Service account + impersonation binding -----

resource "google_service_account" "nomos" {
  account_id   = var.service_account_id
  display_name = "Nomos agent broker"
}

resource "google_service_account_iam_member" "wif_impersonation" {
  service_account_id = google_service_account.nomos.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.nomos.name}/attribute.customer/${var.customer_id}"
}

# Optional: give the SA itself impersonation rights so SignAndCall can mint
# its own creds via iamcredentials.googleapis.com.
resource "google_service_account_iam_member" "sa_self_impersonation" {
  service_account_id = google_service_account.nomos.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.nomos.email}"
}

resource "google_project_iam_member" "sa_roles" {
  for_each = toset(var.service_account_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.nomos.email}"
}

# ----- Outputs -----

output "wif_provider" {
  description = "Full provider resource name — paste into the Nomos dashboard."
  value       = "projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.nomos.workload_identity_pool_id}/providers/${google_iam_workload_identity_pool_provider.nomos.workload_identity_pool_provider_id}"
}

output "service_account_email" {
  description = "Service account email — paste into the Nomos dashboard."
  value       = google_service_account.nomos.email
}

output "project_id" {
  description = "Project id."
  value       = var.project_id
}

data "google_project" "current" {}
