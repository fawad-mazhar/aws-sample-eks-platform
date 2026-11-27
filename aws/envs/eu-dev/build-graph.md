# Dependency Sequence

```text
VPC/subnet discovery
        |
        v
EKS cluster/node/Fargate IAM roles
        |
        v
EKS 1.37 control plane
  - OIDC provider
  - control-plane ENIs
        |
        v
Pre-compute add-ons
  - VPC CNI
  - EKS Pod Identity Agent
        |
        v
Managed node groups + Fargate profiles
        |
        v
EBS/EFS CSI IRSA roles
  - require the cluster OIDC provider
        |
        v
Post-compute add-ons
  - EBS CSI (EBS IRSA role)
  - EFS CSI (EFS IRSA role)
        |
        v
Karpenter and controller AWS resources
  - Pod Identity associations
  - Karpenter interruption queue
  - Karpenter controller/node IAM roles
  - EFS filesystem and mount targets

Pod Identity associations and Karpenter infrastructure require the EKS
cluster name. EFS mounts are created in the Availability Zones represented by
the selected private subnets.

Independent parallel work:
  - ECR repositories and image builds
  - Route53 zone/discovery
```

One valid order; Terraform creates independent steps in parallel.

## Terraform Phase 1

Discover and validate the VPC, subnets and account. Create IAM roles, then the
EKS control plane. Install VPC CNI and the EKS Pod Identity Agent before
compute; this prevents the node-group readiness deadlock.

After pre-compute add-ons are active, create managed node groups and Fargate
profiles. The EBS/EFS CSI IRSA roles then need the cluster OIDC provider,
and only after their role ARNs exist can the matching CSI add-ons install.
Create the ALB Controller, Cluster Autoscaler and Karpenter Pod Identity
associations after the cluster and roles exist. The Karpenter module uses the
cluster name for its queue, controller role, node role and Pod Identity
association. Private subnets receive the Karpenter discovery tag, while the
EKS module sets the node security-group discovery tag.

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
