# nomos-terraforms

Terraform modules for connecting cloud accounts to [Nomos](https://app.auto-nomos.com) via OIDC federation.

No client secrets are stored. Nomos mints a short-lived OIDC token per agent request; your cloud validates it and issues a session credential (1–15 min TTL).

## Modules

| Module | Cloud | What it creates |
|---|---|---|
| [`azurerm-nomos-bootstrap`](./azurerm-nomos-bootstrap) | Azure | App Registration + Service Principal + Federated Identity Credential + Reader role |
| [`aws-nomos-bootstrap`](./aws-nomos-bootstrap) | AWS | IAM OIDC provider + AssumeRoleWithWebIdentity role + ReadOnlyAccess |
| [`google-nomos-bootstrap`](./google-nomos-bootstrap) | GCP | Workload Identity Pool + Provider + Service Account + viewer binding |

## Usage

### Azure

Azure federated identity credentials require **exact subject matches** — wildcards are not supported, and Microsoft blocks `claimsMatchingExpression` for custom OIDC issuers. The module therefore creates one FIC per agent_id (Azure cap: 20 per app). The `verify-poll` id is always included so the dashboard "Verify now" button works; add real agent ids via `additional_agent_ids` as you create agents in Nomos.

```hcl
module "nomos_azure" {
  source = "git::https://github.com/varendra007/nomos-terraforms.git//azurerm-nomos-bootstrap?ref=main"

  customer_id     = "<your-nomos-customer-id>"  # from app.auto-nomos.com/app/settings/workspace
  subscription_id = "<your-azure-subscription-id>"

  additional_agent_ids = [
    # "agt_01H9XYZ...",
  ]
}
```

### AWS

```hcl
module "nomos_aws" {
  source = "git::https://github.com/varendra007/nomos-terraforms.git//aws-nomos-bootstrap?ref=main"

  customer_id       = "<your-nomos-customer-id>"
  region            = "us-east-1"
  nomos_oidc_issuer = "https://id.auto-nomos.com"
}
```

### GCP

```hcl
module "nomos_gcp" {
  source = "git::https://github.com/varendra007/nomos-terraforms.git//google-nomos-bootstrap?ref=main"

  customer_id       = "<your-nomos-customer-id>"
  project_id        = "<your-gcp-project-id>"
  nomos_oidc_issuer = "https://id.auto-nomos.com"
}
```

## Getting your customer_id

Log into [app.auto-nomos.com](https://app.auto-nomos.com) → **Settings → Workspace** → copy **Organization ID**.

## Full setup guide

[app.auto-nomos.com/app/guide/cloud](https://app.auto-nomos.com/app/guide/cloud)
