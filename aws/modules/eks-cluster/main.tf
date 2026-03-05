terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.31.0"
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.15.1"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  endpoint_public_access  = true
  endpoint_private_access = true

  enable_irsa = true

  create_iam_role = false
  iam_role_arn    = var.cluster_role_arn

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  addons = {
    coredns = {
      addon_version               = var.coredns_addon_version
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "PRESERVE"
    }
    kube-proxy = {
      addon_version               = var.kube_proxy_addon_version
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "PRESERVE"
    }
    vpc-cni = {
      addon_version               = var.cni_addon_version
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "PRESERVE"
    }
  }

  enabled_log_types = ["audit", "api", "authenticator"]

  authentication_mode = "API_AND_CONFIG_MAP"

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    for k, v in var.eks_managed_node_groups : k => merge(v, {
      create_iam_role = false
      iam_role_arn    = var.node_group_role_arn
    })
  }

  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
  }

  tags = {
    Name = var.cluster_name
  }
}
