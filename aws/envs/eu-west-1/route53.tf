resource "aws_route53_zone" "main" {
  name = "code-si.com"

  tags = {
    Name = "code-si.com"
  }
}

# ALB lookup — only available after ALB controller + Ingress are deployed.
# Set alb_deployed = true in terraform.tfvars after deployment.
data "aws_lb" "ingress" {
  count = var.alb_deployed ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster"        = local.eks_cluster_name
    "ingress.k8s.aws/stack"        = "kgateway/kgateway-alb"
  }
}

resource "aws_route53_record" "books" {
  count   = var.alb_deployed ? 1 : 0
  zone_id = aws_route53_zone.main.zone_id
  name    = "books.code-si.com"
  type    = "A"

  alias {
    name                   = data.aws_lb.ingress[0].dns_name
    zone_id                = data.aws_lb.ingress[0].zone_id
    evaluate_target_health = true
  }
}
