# Opt-in: use an existing hosted zone when supplied, otherwise create one.
data "aws_route53_zone" "existing" {
  count = local.custom_domain && var.route53_zone_id != null ? 1 : 0

  zone_id      = var.route53_zone_id
  private_zone = false

  lifecycle {
    precondition {
      condition     = var.acm_certificate_arn != null
      error_message = "acm_certificate_arn is required when domain_name is set (the ALB HTTPS listener needs it)."
    }
  }
}

check "existing_route53_zone" {
  assert {
    condition = try(
      !data.aws_route53_zone.existing[0].private_zone &&
      trimsuffix(data.aws_route53_zone.existing[0].name, ".") == trimsuffix(var.domain_name, "."),
      true
    )
    error_message = "route53_zone_id must identify the public hosted zone for domain_name."
  }
}

resource "aws_route53_zone" "main" {
  count = local.custom_domain && var.route53_zone_id == null ? 1 : 0

  name = var.domain_name

  tags = {
    Name = var.domain_name
  }

  lifecycle {
    precondition {
      condition     = var.acm_certificate_arn != null
      error_message = "acm_certificate_arn is required when domain_name is set (the ALB HTTPS listener needs it)."
    }
  }
}

# ALB lookup — only available after ALB controller + Ingress are deployed.
# Pass -var="alb_deployed=true" after deployment. The Ingress sets
# alb.ingress.kubernetes.io/group.name (ENV_PREFIX-ingress), and for an
# explicit IngressGroup the controller tags the ALB's stack with the group
# name, not namespace/ingress-name.
data "aws_lb" "ingress" {
  count = local.custom_domain && var.alb_deployed ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster" = local.eks_cluster_name
    "ingress.k8s.aws/stack" = "${local.resource_prefix}-ingress"
  }
}

resource "aws_route53_record" "app" {
  count = local.custom_domain && var.alb_deployed ? 1 : 0

  zone_id = var.route53_zone_id != null ? data.aws_route53_zone.existing[0].zone_id : aws_route53_zone.main[0].zone_id
  name    = local.app_hostname
  type    = "A"

  alias {
    name                   = data.aws_lb.ingress[0].dns_name
    zone_id                = data.aws_lb.ingress[0].zone_id
    evaluate_target_health = true
  }
}
