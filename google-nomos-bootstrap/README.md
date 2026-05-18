# terraform-google-nomos-bootstrap

Bootstrap a GCP project for Nomos federation. Creates a Workload Identity
Federation pool + provider, plus a service account the federated identity
impersonates.

> **Preview (2026-05-15):** no public mirror yet. Source this module from a
> local path that points at `infra/terraform/google-nomos-bootstrap/` in the
> Nomos repo, or copy the directory into your own Terraform repo and pin to
> a commit SHA. The CLI emits a working snippet automatically:
> `nomos cloud install --gcp --customer-id <id> --nomos-oidc-issuer <url>`.

## Usage

```hcl
module "nomos" {
  # Preview: local-path source. Adjust the relative path to wherever
  # you cloned the credential-broker repo.
  source = "../credential-broker/infra/terraform/google-nomos-bootstrap"

  customer_id       = "your-nomos-customer-uuid"      # from /app/settings/workspace
  project_id        = "my-gcp-project"
  nomos_oidc_issuer = "https://<your-issuer-host>"    # URL of the OIDC issuer you deployed
                                                      # (see apps/oidc-issuer/)
}

output "nomos_paste_into_dashboard" {
  value = {
    wif_provider          = module.nomos.wif_provider
    service_account_email = module.nomos.service_account_email
    project_id            = module.nomos.project_id
  }
}
```

## What it creates

| Resource | Purpose |
|---|---|
| `google_iam_workload_identity_pool.nomos` | The WIF pool. |
| `google_iam_workload_identity_pool_provider.nomos` | OIDC provider with `attribute.customer == "{id}"` condition. |
| `google_service_account.nomos` | SA the WIF principal impersonates. Granted `roles/viewer` by default. |
| `google_service_account_iam_member.wif_impersonation` | Allows the federated identity to call `iamcredentials.googleapis.com:generateAccessToken` on the SA. |

## Federation flow

1. Nomos mints OIDC ID token with `aud=//iam.googleapis.com/<wif-provider>`, `sub=customer/{id}/agent/{agent_id}`.
2. PDP POSTs to `sts.googleapis.com:token` for a federated access token.
3. PDP POSTs to `iamcredentials.googleapis.com:projects/-/serviceAccounts/{sa-email}:generateAccessToken` impersonating the SA.
4. Returned token is a Bearer for `*.googleapis.com`.

## Limits

- WIF attribute condition pins the federation to `customer == {id}` — cross-customer cred sharing impossible.
- Default SA role is `roles/viewer`. Narrow via `service_account_roles` for production.
- `iam.serviceAccountTokenCreator` on the SA is granted to itself so the impersonation hop works without extra plumbing.
