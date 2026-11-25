output "cluster_role_arn" {
  value = module.eks_iam.cluster_role_arn
}

output "node_group_role_arn" {
  value = module.eks_iam.node_group_role_arn
}

output "vpc_id" {
  value = data.aws_vpc.this.id
}

output "private_subnet_ids" {
  value = data.aws_subnets.private.ids
}

output "public_subnet_ids" {
  value = data.aws_subnets.public.ids
}

output "cluster_endpoint" {
  value = module.eks_cluster.cluster_endpoint
}

output "cluster_name" {
  value = module.eks_cluster.cluster_name
}

output "oidc_provider_arn" {
  value = module.eks_cluster.oidc_provider_arn
}

output "oidc_provider" {
  value = module.eks_cluster.oidc_provider
}

output "alb_controller_role_arn" {
  value = module.alb_controller_pod_identity.role_arn
}

output "fargate_role_arn" {
  value = module.eks_fargate_iam.fargate_role_arn
}

output "ecr_repository_urls" {
  value = { for k, v in module.ecr : k => v.repository_url }
}

output "route53_zone_id" {
  value = local.custom_domain ? aws_route53_zone.main[0].zone_id : null
}

output "route53_nameservers" {
  value = local.custom_domain ? aws_route53_zone.main[0].name_servers : null
}

output "app_hostname" {
  value = local.custom_domain ? local.app_hostname : null
}

output "ebs_csi_role_arn" {
  value = module.ebs_csi_irsa.role_arn
}

output "efs_csi_role_arn" {
  value = module.efs_csi_irsa.role_arn
}

output "efs_file_system_id" {
  value = aws_efs_file_system.this.id
}

output "cluster_autoscaler_role_arn" {
  value = module.cluster_autoscaler_pod_identity.role_arn
}

output "karpenter_controller_role_arn" {
  value = module.karpenter.iam_role_arn
}

output "karpenter_node_role_name" {
  value = module.karpenter.node_iam_role_name
}

output "karpenter_queue_name" {
  value = module.karpenter.queue_name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks_cluster.cluster_name} --region ${var.region}"
}

# Read by bin/cluster-config.sh: becomes the kube-system/cluster-information
# ConfigMap that the controllers read at runtime.
output "cluster_information" {
  value = {
    "cluster-name"     = module.eks_cluster.cluster_name
    "aws-region"       = var.region
    "aws-vpc-id"       = data.aws_vpc.this.id
    "cluster-endpoint" = module.eks_cluster.cluster_endpoint
    "karpenter-queue"  = module.karpenter.queue_name
  }
}

# Read by bin/cluster-config.sh: the variables Flux substitutes into the
# manifests (flux-system/cluster-vars ConfigMap, postBuild.substituteFrom).
# flux/envs/eu-west-1/cluster-vars.example.env lists the same keys.
output "flux_vars" {
  value = {
    ECR_REGISTRY        = local.ecr_registry
    ENV_PREFIX          = local.env_prefix
    CLUSTER_NAME        = module.eks_cluster.cluster_name
    KARPENTER_NODE_ROLE = module.karpenter.node_iam_role_name
    APP_HOSTNAME        = local.app_hostname
    ACM_CERTIFICATE_ARN = var.acm_certificate_arn == null ? "" : var.acm_certificate_arn
  }
}
