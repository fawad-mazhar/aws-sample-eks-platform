locals {
  ecr_repositories = {
    nats = {
      image_tag = "2.12.3"
    }
    nats-box = {
      image_tag = "0.19.2"
    }
    kgateway-discovery = {
      image_tag = "1.20.9"
    }
    kgateway-envoy = {
      image_tag = "1.20.9"
    }
    kgateway-gloo = {
      image_tag = "1.20.9"
    }
    keda = {
      image_tag = "2.18.3"
    }
    keda-metrics-apiserver = {
      image_tag = "2.18.3"
    }
    keda-admission-webhooks = {
      image_tag = "2.18.3"
    }
  }
}

module "ecr" {
  source   = "../modules/ecr"
  for_each = local.ecr_repositories

  repository_name = "${local.env_prefix}/${each.key}"
  source_path     = "${path.module}/../../applications/${each.key}"
  image_tag       = each.value.image_tag
  region          = var.region
  aws_profile     = "nlaclassic"
}
