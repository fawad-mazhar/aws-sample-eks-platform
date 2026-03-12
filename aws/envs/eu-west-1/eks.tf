module "eks_cluster" {
  source = "../../modules/eks-cluster"

  cluster_name        = local.eks_cluster_name
  cluster_role_arn    = module.eks_iam.cluster_role_arn
  node_group_role_arn = module.eks_iam.node_group_role_arn
  fargate_role_arn    = module.eks_fargate_iam.fargate_role_arn
  vpc_id              = data.aws_vpc.this.id
  private_subnet_ids  = data.aws_subnets.private.ids

  ebs_csi_addon_version  = "v1.43.0-eksbuild.1"
  ebs_csi_addon_role_arn = module.ebs_csi_irsa.role_arn
  efs_csi_addon_version  = "v2.2.0-eksbuild.1"
  efs_csi_addon_role_arn = module.efs_csi_irsa.role_arn

  eks_managed_node_groups = {
    platform = {
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 3
      desired_size   = 1

      labels = {
        role = "platform"
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      tags = {
        "k8s.io/cluster-autoscaler/enabled"                   = "true"
        "k8s.io/cluster-autoscaler/${local.eks_cluster_name}" = "owned"
      }
    }

    services = {
      instance_types = ["t3.large"]
      min_size       = 1
      max_size       = 5
      desired_size   = 2

      labels = {
        role = "services"
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      tags = {
        "k8s.io/cluster-autoscaler/enabled"                   = "true"
        "k8s.io/cluster-autoscaler/${local.eks_cluster_name}" = "owned"
      }
    }
  }

  fargate_profiles = {
    fargate = {
      selectors = [
        {
          namespace = "fargate"
        }
      ]
    }
    kgateway = {
      selectors = [
        {
          namespace = "kgateway"
        }
      ]
    }
    sample-app = {
      selectors = [
        {
          namespace = "sample-app"
          labels = {
            app = "fastapi-app"
          }
        }
      ]
    }
  }
}
