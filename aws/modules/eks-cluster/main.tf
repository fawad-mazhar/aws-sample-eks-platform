terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.30.2"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  endpoint_public_access  = true
  endpoint_private_access = true

  enable_irsa = true

  create_iam_role = false
  iam_role_arn    = var.cluster_role_arn

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  addons = merge(
    {
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
        before_compute              = true
        resolve_conflicts_on_create = "OVERWRITE"
        resolve_conflicts_on_update = "PRESERVE"
      }
      # Serves EKS Pod Identity credentials (ALB controller, Cluster
      # Autoscaler, Karpenter). Installed before compute so the agent is
      # running before any controller pod starts.
      eks-pod-identity-agent = {
        addon_version               = var.pod_identity_agent_addon_version
        before_compute              = true
        resolve_conflicts_on_create = "OVERWRITE"
        resolve_conflicts_on_update = "PRESERVE"
      }
    },
    # Keyed on the version only. The role ARN isn't known until the role is
    # created, and an unknown condition here would make the whole addons map
    # unknown at plan time, which the EKS module can't for_each over.
    var.ebs_csi_addon_version != "" ? {
      aws-ebs-csi-driver = {
        addon_version               = var.ebs_csi_addon_version
        service_account_role_arn    = var.ebs_csi_addon_role_arn
        resolve_conflicts_on_create = "OVERWRITE"
        resolve_conflicts_on_update = "PRESERVE"
      }
    } : {},
    var.efs_csi_addon_version != "" ? {
      aws-efs-csi-driver = {
        addon_version               = var.efs_csi_addon_version
        service_account_role_arn    = var.efs_csi_addon_role_arn
        resolve_conflicts_on_create = "OVERWRITE"
        resolve_conflicts_on_update = "PRESERVE"
      }
    } : {}
  )

  enabled_log_types = ["audit", "api", "authenticator"]

  authentication_mode = "API_AND_CONFIG_MAP"

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    for k, v in var.eks_managed_node_groups : k => merge(v, {
      create_iam_role = false
      iam_role_arn    = var.node_group_role_arn
    })
  }

  fargate_profiles = {
    for k, v in var.fargate_profiles : k => merge(v, {
      create_iam_role = false
      iam_role_arn    = var.fargate_role_arn
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
