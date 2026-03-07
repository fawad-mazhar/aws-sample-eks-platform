terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.31.0"
    }
  }
}

resource "aws_ecr_repository" "this" {
  name                 = var.repository_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = var.repository_name
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "terraform_data" "docker_build_push" {
  triggers_replace = sha1(join("", [for f in fileset(var.source_path, "**") : filesha1("${var.source_path}/${f}")]))

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      aws ecr get-login-password --region ${var.region} --profile ${var.aws_profile} | docker login --username AWS --password-stdin ${aws_ecr_repository.this.repository_url}
      docker build -t ${aws_ecr_repository.this.repository_url}:${var.image_tag} ${abspath(var.source_path)}
      docker push ${aws_ecr_repository.this.repository_url}:${var.image_tag}
    EOT
  }
}
