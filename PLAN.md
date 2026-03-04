# AWS Sample EKS Platform — Implementation Plan

## Problem Statement
Build a complete AWS EKS platform from scratch, covering cluster creation, IAM roles, node groups, Fargate profiles, storage (EBS/EFS), ingress (ALB), autoscaling (Cluster Autoscaler/Karpenter), and ECR integration. All AWS resources are managed via Terraform; all Kubernetes resources via Flux/Kustomize.

## Current State
The repository is empty aside from `TASKS.md`, `README.md`, and three empty directories: `aws/`, `flux/`, `applications/`. The `dev` branch is active.

## Conventions (derived from reference projects)

### Terraform (`aws/`)
Based on `aws-landingzone` and `github-operations`:
- Terraform `~> 1.14.0`, AWS provider `6.31.0`
- File layout per environment: `main.tf` (backend + providers), `variables.tf`, `terraform.tfvars`, `locals.tf`, per-resource files (`eks.tf`, `iam.tf`, etc.)
- Reusable modules under `aws/modules/`; root config under `aws/eu-west-1/` (single-region for now)
- S3 backend with DynamoDB lock (we'll use a local backend initially, switchable to S3 later)
- `env_prefix` pattern: `{account_name}-{environment}-{region}`
- `data "aws_iam_policy_document"` preferred for IAM policies
- Use `terraform-aws-modules/eks/aws` community module (v21.x) for the cluster, consistent with the landingzone
- AWS profile: `nlaclassic`, region: `eu-west-1`, existing VPC/subnets (looked up via data sources), new security groups
- `.gitignore`: `.terraform/`, `*.tfstate`, `*.tfstate.*`

### Flux/Kustomize (`flux/`)
Based on `flux-admin-v2` and `flux-dev-v2`:
- Structure: `flux/modules/<component>/` for reusable K8s manifests (kustomization.yaml + resource YAMLs)
- `flux/base/` for shared base resources (namespaces, etc.)
- `flux/envs/<env>/` for environment-specific patches and kustomizations
- Each module directory has a `kustomization.yaml` listing its resources
- Admin-level components (CSI StorageClass, ALB controller, cluster-autoscaler, logging) go in flux as they're K8s resources

### Applications (`applications/`)
- Dockerfiles following `base-images` conventions (.dockerignore + Dockerfile per app)
- Can optionally be nested under `aws/` if Terraform handles ECR build+push

## Directory Structure
```
aws-sample-eks-platform/
├── aws/
│   ├── modules/
│   │   ├── eks-cluster/          # EKS cluster + managed node groups
│   │   ├── eks-iam/              # Cluster role, node group role, Fargate role
│   │   ├── eks-oidc-iam/         # OIDC-based roles (EBS CSI, EFS CSI, ALB, autoscaler)
│   │   ├── eks-fargate/          # Fargate profile
│   │   ├── eks-karpenter/        # Karpenter IAM roles
│   │   └── ecr/                  # ECR repository management
│   └── eu-west-1/
│       ├── main.tf
│       ├── variables.tf
│       ├── terraform.tfvars
│       ├── locals.tf
│       ├── data.tf               # VPC, subnet, existing resource lookups
│       ├── eks.tf                # EKS cluster instantiation
│       ├── iam.tf                # IAM role instantiation
│       ├── fargate.tf
│       ├── ecr.tf
│       └── outputs.tf
├── flux/
│   ├── base/
│   │   └── kustomization.yaml   # Namespaces and base resources
│   ├── modules/
│   │   ├── aws-csi/             # gp3 StorageClass
│   │   ├── aws-load-balancer-controller/
│   │   ├── cluster-autoscaler/
│   │   ├── aws-logging/         # aws-logging ConfigMap for Fargate
│   │   └── sample-app/          # Demo nginx with LoadBalancer service
│   └── envs/
│       └── dev/
│           └── kustomization.yaml
├── applications/
│   └── sample-app/
│       ├── Dockerfile
│       └── .dockerignore
├── TASKS.md
└── README.md
```

## Phases

### Phase 1: Foundation — EKS Cluster + IAM + kubectl Access
Terraform (`aws/`):
- `aws/eu-west-1/main.tf`: provider config with `nlaclassic` profile, local backend, required_version `~> 1.14.0`, AWS provider `6.31.0`
- `aws/eu-west-1/data.tf`: look up existing VPC by tag/filter, subnets (private for EKS, public for ALB)
- `aws/modules/eks-iam/`: IAM cluster role (`AmazonEKSClusterPolicy`) and node group role (`AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`)
- `aws/modules/eks-cluster/`: wrap `terraform-aws-modules/eks/aws` v21.x — cluster creation with IRSA, public+private endpoints, coredns/kube-proxy/vpc-cni addons, security group rules (node-to-node all, egress all)
- `aws/eu-west-1/eks.tf`: instantiate modules
- `aws/eu-west-1/outputs.tf`: cluster endpoint, cluster name, OIDC provider ARN, kubeconfig update command
- `.gitignore` at repo root

Validation:
- `terraform init && terraform plan` succeeds
- `aws eks update-kubeconfig --name <cluster> --region eu-west-1 --profile nlaclassic`
- `kubectl get nodes` returns ready

### Phase 2: Managed Node Groups
Terraform (`aws/`):
- Extend `aws/modules/eks-cluster/` with `eks_managed_node_groups` variable (name, instance types, min/max/desired, disk size, labels, taints)
- At minimum create a `platform` node group (small instances for system workloads) and a `services` node group (for application workloads)
- EBS encryption by default, gp3 volumes
- Node additional IAM policies (ECR read, CloudWatch logs, SSM)
- Tag ASGs for cluster-autoscaler discovery

### Phase 3: Fargate Profile + Logging
Terraform (`aws/`):
- `aws/modules/eks-fargate/`: IAM role for Fargate with `AmazonEKSFargatePodExecutionRolePolicy`, Fargate profile resource targeting a specific namespace+labels
- `aws/eu-west-1/fargate.tf`: instantiate with namespace selector (e.g., `fargate` namespace)

Flux (`flux/`):
- `flux/modules/aws-logging/`: `aws-logging` ConfigMap in `aws-observability` namespace for Fargate log routing to CloudWatch
- `flux/base/`: namespace definitions (at minimum `default`, `kube-system`—Fargate target namespace)

### Phase 4: Expose Application via LoadBalancer Service
Flux (`flux/`):
- `flux/modules/sample-app/`: Deployment (nginx) + Service type LoadBalancer, kustomization.yaml
- Environment patch in `flux/envs/dev/`

Applications:
- `applications/sample-app/Dockerfile`: simple nginx container

### Phase 5: EBS/EFS Storage
Terraform (`aws/`):
- `aws/modules/eks-oidc-iam/`: IRSA roles for EBS CSI driver and EFS CSI driver (trust policy with OIDC, attach `AmazonEBSCSIDriverPolicy` / `AmazonEFSCSIDriverPolicy`)
- Install EBS CSI and EFS CSI as EKS addons via the cluster module (addon_version + service_account_role_arn)
- KMS key for EBS encryption (with policy allowing autoscaling service-linked role and cluster role)

Flux (`flux/`):
- `flux/modules/aws-csi/gp3.yaml`: gp3 StorageClass (default), encrypted, WaitForFirstConsumer
- Example PVC manifest and StatefulSet with volumeClaimTemplates in `flux/modules/sample-app/` or a dedicated storage-demo module
- EFS: PersistentVolume + PVC pointing to EFS filesystem ID (EFS filesystem created in Terraform)

### Phase 6: Ingress Controller + ALB
Terraform (`aws/`):
- `aws/modules/eks-oidc-iam/`: IRSA role for AWS Load Balancer Controller (comprehensive policy from reference project: ec2, elasticloadbalancing, cognito, acm, waf, shield, iam:CreateServiceLinkedRole)

Flux (`flux/`):
- `flux/modules/aws-load-balancer-controller/`: Full ALB controller deployment — CRDs (IngressClassParams, TargetGroupBinding), ClusterRole, RoleBinding, Deployment, Service, IngressClass `alb`, webhook configuration
- cert-manager dependency (Certificate + Issuer for webhook TLS) — or simplified self-managed cert approach
- Ingress resource for sample-app routed via ALB

### Phase 7: Scaling — Cluster Autoscaler + Karpenter
Terraform (`aws/`):
- `aws/modules/eks-oidc-iam/`: IRSA role for cluster-autoscaler (autoscaling describe/set/terminate, ec2 describe, eks describe, scoped by cluster tag)
- `aws/modules/eks-karpenter/`: Karpenter controller IRSA role (ec2 fleet/launch template/instances, ssm parameters, iam PassRole, eks describe) + Karpenter node role (EKSWorkerNodePolicy, ECR read, CNI) + instance profile

Flux (`flux/`):
- `flux/modules/cluster-autoscaler/`: Deployment, RBAC (ClusterRole, Role, bindings), priority-expander ConfigMap, cluster-name ConfigMap
- For Karpenter: NodePool and EC2NodeClass CRDs (deployed via Flux after Karpenter Helm chart or manifests)
- Observability: Prometheus scrape annotations on autoscaler pods (`prometheus.io/scrape: "true"`, `prometheus.io/port: "8085"`)

### Phase 8: ECR Integration
Terraform (`aws/`):
- `aws/modules/ecr/`: `aws_ecr_repository` with image scanning, lifecycle policy, encryption + `null_resource` with `local-exec` for Docker build+push
- The module hashes the application source directory (`applications/<app>/`); on change, it runs `aws ecr get-login-password | docker login`, `docker build`, `docker push` via `local-exec` provisioner
- Uses `triggers = { src_hash = sha256(fileset(...)) }` to detect source changes — only rebuilds when Dockerfile or app code changes (same idempotency as `cdk-ecr-deployment`)
- `aws/eu-west-1/ecr.tf`: create repositories for sample-app (and future services)
- Node IAM roles already have `AmazonEC2ContainerRegistryReadOnly` from Phase 2

Flux (`flux/`):
- Update sample-app deployment image to use ECR repository URI

Applications:
- `applications/sample-app/Dockerfile` + `.dockerignore` — the source directory that the ecr module hashes and builds

## Backlog

Status: **PENDING** | **IN PROGRESS** | **DONE**

- PENDING — Phase 1: Foundation — EKS Cluster + IAM + kubectl Access
- PENDING — Phase 2: Managed Node Groups
- PENDING — Phase 3: Fargate Profile + Logging
- PENDING — Phase 4: Expose Application via LoadBalancer Service
- PENDING — Phase 5: EBS/EFS Storage
- PENDING — Phase 6: Ingress Controller + ALB
- PENDING — Phase 7: Scaling — Cluster Autoscaler + Karpenter
- PENDING — Phase 8: ECR Integration

Each phase is independently deployable/undoable. Terraform `destroy` tears down AWS resources; `kubectl delete -k` removes Flux resources.

Phases are executed one at a time. After each phase, a commit message is suggested and execution pauses until the user commits and gives the go-ahead.

## Notes
- The `nlaclassic` AWS profile has no `role_arn` or `source_profile` — it likely relies on credential_process or SSO; we'll use it as-is with `profile = "nlaclassic"` in the provider
- VPC and subnets are existing — we'll use data sources with appropriate tags/filters to discover them; the user will need to provide VPC ID or tag filters in `terraform.tfvars`
- Security groups are created fresh per the requirements
- We'll keep the plan simple for a sample/reference project — no multi-environment complexity initially, just `dev` environment targeting `eu-west-1`
