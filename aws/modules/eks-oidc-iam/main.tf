terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.31.0"
    }
  }
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.env_prefix}-${var.role_name}"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = {
    Name = "${var.env_prefix}-${var.role_name}"
  }
}

resource "aws_iam_role_policy" "this" {
  name   = var.role_name
  role   = aws_iam_role.this.id
  policy = var.policy_json
}
