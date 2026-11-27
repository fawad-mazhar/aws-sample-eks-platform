# Dependency Sequence

```text
VPC/subnet discovery
        |
        v
EKS, node, Fargate and CSI IAM roles
        |
        v
EKS 1.37 control plane
  - OIDC provider
  - control-plane ENIs
        |
        +---------------------------+
        v                           v
Pre-compute add-ons            EFS filesystem
  - VPC CNI                   3 AZ mount targets
  - EKS Pod Identity Agent
        |
        v
Managed node groups + Fargate profiles
        |
        v
Post-compute CSI add-ons
  - EBS CSI (EBS IRSA role)
  - EFS CSI (EFS IRSA role)
        |
        +---------------------------+
        v                           v
Pod Identity associations         Karpenter infrastructure
  - ALB controller                 - Pod Identity association
  - Cluster Autoscaler             - interruption queue
  - Karpenter controller            - controller/node IAM roles

Karpenter infrastructure and Pod Identity associations require the EKS
cluster name and are not prerequisites for CSI add-on role creation.

Independent parallel work:
  - ECR repositories and image builds
  - Route53 zone/discovery
```

## Terraform Phase 1

Discover and validate the VPC, subnets and account. Create IAM roles, then the
EKS control plane. Install VPC CNI and the EKS Pod Identity Agent before
compute; this prevents the node-group readiness deadlock.

After pre-compute add-ons are active, create managed node groups and Fargate
profiles. Then create the EBS/EFS CSI IRSA roles and install the CSI add-ons.
Create the ALB Controller, Cluster Autoscaler and Karpenter Pod Identity
associations after the cluster and roles exist. The Karpenter module uses the
cluster name for its queue, controller role, node role and Pod Identity
association; tag private subnets and the node security group for discovery.

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
