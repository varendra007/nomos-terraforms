# terraform-azurerm-nomos-bootstrap

Bootstrap an Azure tenant to trust the Nomos OIDC issuer. Creates an App
Registration + federated identity credential + a Reader role assignment so
the Nomos PDP can broker short-lived access tokens for agent requests
against `management.azure.com`.

> **Preview (2026-05-15):** no public mirror yet. Source this module from
> a local path that points at `infra/terraform/azurerm-nomos-bootstrap/` in
> the Nomos repo, or copy the directory into your own Terraform repo and
> pin to a commit SHA. The CLI emits a working snippet automatically:
> `nomos cloud install --azure --customer-id <id> --nomos-oidc-issuer <url>`.

## Usage

```hcl
module "nomos" {
  # Preview: local-path source. Adjust the relative path to wherever
  # you cloned the credential-broker repo.
  source = "../credential-broker/infra/terraform/azurerm-nomos-bootstrap"

  customer_id       = "your-nomos-customer-uuid"      # from /app/settings/workspace
  subscription_id   = "00000000-0000-0000-0000-000000000000"
  nomos_oidc_issuer = "https://<your-issuer-host>"    # URL of the OIDC issuer you deployed
                                                      # (see apps/oidc-issuer/)

  # Optional — narrow to one RG instead of subscription scope:
  # resource_group_name = "rg-agent-sandbox"
}

output "nomos_paste_into_dashboard" {
  value = {
    app_object_id   = module.nomos.app_object_id
    app_client_id   = module.nomos.app_client_id
    tenant_id       = module.nomos.tenant_id
    subscription_id = module.nomos.subscription_id
  }
}
```

## What it creates

| Resource | Purpose |
|---|---|
| `azuread_application.nomos` | App Registration the federation trusts. |
| `azuread_service_principal.nomos` | SP the role assignment binds to. |
| `azuread_application_federated_identity_credential.nomos` | Trust block — issuer = `id.auto-nomos.com`, subject = `customer/{id}/agent/*`. |
| `azurerm_role_assignment.nomos` | Reader at subscription or RG scope. |

## Variables

| Name | Description | Default |
|---|---|---|
| `customer_id` | Nomos customer id. Required. | — |
| `subscription_id` | Azure subscription id. Required. | — |
| `nomos_oidc_issuer` | Public Nomos issuer URL. | `https://id.auto-nomos.com` |
| `resource_group_name` | Narrow Reader to one RG. Empty = subscription scope. | `""` |
| `app_display_name` | App Registration display name. | `nomos-agent-broker` |
| `role_definition_name` | Built-in role to assign. M1 = Reader. | `Reader` |
| `agent_subject` | Override federated cred subject (rarely needed). | `customer/{id}/agent/*` |

## Outputs

Paste these into the Nomos dashboard at `/app/cloud/connect/azure`:

- `app_object_id`
- `app_client_id`
- `tenant_id`
- `subscription_id`

## How the federation works

1. Nomos mints an OIDC ID token signed by an RS256 key. In preview the
   signer can be in-memory (dev) or AWS KMS-backed (`OIDC_KMS_KEY_REF`).
2. Token claims include `iss=<your nomos_oidc_issuer>`, `sub=customer/{id}/agent/{agent_id}`,
   `aud=api://AzureADTokenExchange`.
3. Nomos POSTs the token to `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token`
   with `grant_type=client_credentials`, `client_assertion_type=...:jwt-bearer`,
   `client_assertion=<id-token>`, `scope=https://management.azure.com/.default`.
4. AAD validates the token against `<your nomos_oidc_issuer>/.well-known/openid-configuration`
   and the federated identity credential on the App Registration, returns
   an AAD access token.
5. PDP attaches the AAD token as `Authorization: Bearer` to ARM calls.

No long-lived secrets leave the customer's tenant. Nomos never holds a
client secret or service-principal password.

## Limits

- Azure caps federated credentials at **20 per app**. M1 uses a single
  wildcard subject (`customer/{id}/agent/*`); customers with >20 agents
  per tenant should upgrade to flexible federated identity credentials
  (M2).
- Reader is the broadest role this module assigns. To do writes you'll
  add additional `azurerm_role_assignment` blocks in your own Terraform —
  the M1 module intentionally restricts to read.
