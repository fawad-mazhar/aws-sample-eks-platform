# Dependency Sequence

```text
VPC/subnet discovery
        |
        v
EKS/Fargate IAM roles
        |
        v
EKS 1.37 cluster
  - managed node groups
  - Fargate profiles
  - add-ons
  - OIDC provider
        |
        +---------------------------+
        v                           v
EBS/EFS CSI IRSA roles       EFS filesystem
        |                           |
        v                           v
Pod Identity associations      EFS mount targets
  - ALB controller
  - Cluster Autoscaler
  - Karpenter

Independent parallel work:
  - ECR repositories and image builds
  - Karpenter infrastructure
  - Route53 zone/discovery
```

## Terraform Phase 1

Discover and validate the VPC, subnets and account. Create IAM roles, then the
EKS cluster with managed nodes, Fargate profiles and add-ons. After the cluster:

- Create EBS/EFS CSI IRSA roles and EFS mount targets.
- Create Pod Identity associations for the ALB Controller, Cluster Autoscaler
  and Karpenter.
- Tag private subnets for Karpenter discovery.

Private subnets must belong to the VPC and span at least two Availability
Zones. ECR builds and Route53 zone discovery can proceed independently.

## Kubernetes

Configure `kubectl`, wait for Ready nodes, establish CRDs/namespaces, and apply
Terraform-derived ConfigMaps. Then deploy controllers and workloads. Required
readiness gates:

- CRDs before custom resources.
- ALB Controller before an ALB Ingress.
- CloudNativePG operator before a database `Cluster`.
- Karpenter controller and CRDs before `NodePool`/`EC2NodeClass`.

## Terraform Phase 2

After the Ingress has a healthy ALB target, run:

```bash
terraform -chdir=aws/envs/eu-dev plan \
  -var="alb_deployed=true" \
  -out=tfplan
terraform -chdir=aws/envs/eu-dev apply tfplan
```

This creates the custom-domain Route53 alias only after the ALB exists.
