variable "repository_name" {
  type        = string
  description = "Name of the ECR repository."
}

variable "source_path" {
  type        = string
  description = "Path to the application source directory containing Dockerfile."
}

variable "image_tag" {
  type        = string
  description = "Tag for the Docker image."
}

variable "region" {
  type        = string
  description = "AWS region for ECR."
}

variable "aws_profile" {
  type        = string
  description = "AWS CLI profile for ECR authentication."
}

variable "force_delete" {
  type        = bool
  description = "Force delete the ECR repository and all images."
  default     = false
}
