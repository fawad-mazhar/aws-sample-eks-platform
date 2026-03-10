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
  value = module.alb_controller_irsa.role_arn
}

output "fargate_role_arn" {
  value = module.eks_fargate_iam.fargate_role_arn
}

output "ecr_repository_urls" {
  value = { for k, v in module.ecr : k => v.repository_url }
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks_cluster.cluster_name} --region ${var.region} --profile nlaclassic"
}
