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
    prometheus = {
      image_tag = "v3.9.1"
    }
    prometheus-config-reloader = {
      image_tag = "v0.88.0"
    }
    prometheus-nats-exporter = {
      image_tag = "0.18.0"
    }
    sealed-secrets-controller = {
      image_tag = "0.34.0"
    }
    sample-app = {
      image_tag = "1.0.0"
    }
  }
}

module "ecr" {
  source   = "../../modules/ecr"
  for_each = local.ecr_repositories

  repository_name = "${local.env_prefix}/${each.key}"
  source_path     = "${path.module}/../../../applications/${each.key}"
  image_tag       = each.value.image_tag
  region          = var.region
  aws_profile     = "nlaclassic"
}
