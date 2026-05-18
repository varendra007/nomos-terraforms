# Nomos — AWS federation bootstrap module.
#
# Creates IAM OIDC provider + IAM role trusted by Nomos's OIDC issuer.
# The role's trust policy keys on the OIDC token `sub` claim matching
# the customer's agent identifier pattern.
#
# Final home: github.com/auto-nomos/terraform-aws-nomos-bootstrap.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "nomos_oidc_issuer" {
  description = "Public URL of the Nomos OIDC issuer."
  type        = string
  default     = "https://id.auto-nomos.com"
}

variable "customer_id" {
  description = "Nomos customer id — appears in the trust policy sub pattern."
  type        = string
}

variable "region" {
  description = "AWS region for the STS endpoint and role-assume."
  type        = string
  default     = "us-east-1"
}

variable "role_name" {
  description = "Name of the IAM role Nomos assumes."
  type        = string
  default     = "nomos-agent-broker"
}

variable "managed_policy_arns" {
  description = "Managed policies attached to the role. M5 defaults to ReadOnlyAccess."
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
}

variable "additional_policy_json" {
  description = "Optional inline policy JSON for narrower permissions."
  type        = string
  default     = ""
}

# JWKS thumbprint for the IAM OIDC provider. AWS expects the SHA-1
# fingerprint of the leaf certificate served at the issuer URL. We
# compute it at apply time from the live TLS handshake — this is the
# pattern AWS docs recommend (eks/iam-oidc-thumbprint blog), and it
# self-heals on cert rotation since `terraform apply` recomputes.
#
# Override only for offline environments where we cannot reach the
# issuer at apply time.
variable "oidc_thumbprint" {
  description = "Override SHA-1 thumbprint of the issuer's TLS leaf. Empty = computed via data.tls_certificate at apply time."
  type        = string
  default     = ""
}

data "tls_certificate" "nomos_issuer" {
  url = var.nomos_oidc_issuer
}

# ----- OIDC provider -----

resource "aws_iam_openid_connect_provider" "nomos" {
  url            = var.nomos_oidc_issuer
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    var.oidc_thumbprint == ""
    ? data.tls_certificate.nomos_issuer.certificates[0].sha1_fingerprint
    : var.oidc_thumbprint,
  ]
}

# ----- IAM role -----

data "aws_caller_identity" "current" {}

locals {
  issuer_host = replace(var.nomos_oidc_issuer, "https://", "")
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.nomos.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "${local.issuer_host}:sub"
      values   = ["customer/${var.customer_id}/agent/*"]
    }
  }
}

resource "aws_iam_role" "nomos" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = toset(var.managed_policy_arns)
  role       = aws_iam_role.nomos.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "inline" {
  count  = var.additional_policy_json == "" ? 0 : 1
  name   = "${var.role_name}-inline"
  role   = aws_iam_role.nomos.name
  policy = var.additional_policy_json
}

# ----- Outputs -----

output "role_arn" {
  description = "Paste into the Nomos dashboard as the role to assume."
  value       = aws_iam_role.nomos.arn
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN — informational."
  value       = aws_iam_openid_connect_provider.nomos.arn
}

output "account_id" {
  description = "AWS account id."
  value       = data.aws_caller_identity.current.account_id
}

output "region" {
  description = "Region passed in. PDP defaults to this for STS calls."
  value       = var.region
}
