# IAM role for a Kubernetes service account via EKS Pod Identity. Unlike IRSA,
# the service account needs no eks.amazonaws.com/role-arn annotation: the
# association below binds the role to namespace/service-account, so manifests
# carry no account ID. Requires the eks-pod-identity-agent add-on, and pods on
# EC2 nodes (Pod Identity is not available on Fargate).
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
  }
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
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

resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account_name
  role_arn        = aws_iam_role.this.arn

  tags = {
    Name = "${var.env_prefix}-${var.role_name}"
  }
}
