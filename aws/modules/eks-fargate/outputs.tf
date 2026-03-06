output "fargate_role_arn" {
  value = aws_iam_role.fargate.arn
}

output "fargate_role_name" {
  value = aws_iam_role.fargate.name
}
