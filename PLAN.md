# AWS Sample EKS Platform — Implementation Plan

## Problem Statement
Build a complete AWS EKS platform from scratch, covering cluster creation, IAM roles, node groups, Fargate profiles, storage (EBS/EFS), ingress (ALB), autoscaling (Cluster Autoscaler/Karpenter), and ECR integration. All AWS resources are managed via Terraform; all Kubernetes resources via Flux/Kustomize.

## Current State
The repository is empty aside from `TASKS.md`, `README.md`, and three empty directories: `aws/`, `flux/`, `applications/`. The `dev` branch is active.

## Conventions (derived from reference projects)

### Terraform (`aws/`)
Based on `aws-landingzone` and `github-operations`:
- Terraform `~> 1.14.0`, AWS provider `6.31.0` (pinned exact, matching the newer `audit` config in the reference)
- File layout per environment: `main.tf` (backend + providers), `variables.tf`, `terraform.tfvars`, `locals.tf`, per-resource files (`eks.tf`, `iam.tf`, etc.)
- Reusable modules under `aws/modules/`; environment config under `aws/envs/<region>/` (single-region for now, mirrors `flux/envs/<region>/`)
- S3 backend with DynamoDB lock (we'll use a local backend initially, switchable to S3 later)
- `env_prefix` pattern: `{account_name}-{region}` (e.g., `nlaclassic-eu-west-1`)
- `locals.tf` must define at minimum: `env_prefix = "${var.account_name}-${var.region}"`, `eks_cluster_name = "${local.env_prefix}-eks"`
- `default_tags` in the AWS provider block: `environment`, `account-name` (matching reference convention)
- `data "aws_iam_policy_document"` preferred for IAM policies
- Note: the reference `aws-landingzone` uses a custom internal EKS module, not the community module. For this sample project we use `terraform-aws-modules/eks/aws` (v21.x) as a pragmatic simplification — it provides the same functionality with less boilerplate
- AWS profile: `nlaclassic`, region: `eu-west-1`, existing VPC/subnets (looked up via data sources), new security groups
- `variables.tf` must define `account_name` (string), `region` (string with validation restricting to `eu-west-1`), `environment` (string), `vpc_id` (string); subnets discovered via `map-public-ip-on-launch` filter
- `.gitignore`: `.terraform/`, `*.tfstate`, `*.tfstate.*` (already present in repo)

### Flux/Kustomize (`flux/`)
Based on `flux-admin-v2` and `flux-dev-v2`:
- Structure: `flux/modules/<component>/` for reusable K8s manifests (kustomization.yaml + resource YAMLs)
- `flux/base/` for shared base resources — individual namespace YAML files (e.g., `sample-app-namespace.yaml`, `aws-observability-namespace.yaml`) plus a `kustomization.yaml` listing them (matching `flux-admin-v2` pattern)
- `flux/envs/<region>/` for environment-specific patches and kustomizations (matches `aws/<region>/` naming)
- Each module directory has a `kustomization.yaml` listing its resources
- `namespace:` is set in the env overlay kustomization.yaml, not repeated in each resource YAML
- `commonLabels:` used in module kustomization.yaml to label all resources
- `patchesStrategicMerge:` for env-specific overrides (deployment-patch.yaml, etc.)
- Admin-level components (CSI StorageClass, ALB controller, cluster-autoscaler, logging) go in flux as they're K8s resources

### Applications (`applications/`)
- Dockerfiles following `base-images` conventions: pin images by SHA256 digest (`FROM image:tag@sha256:...`), include `# MULTIARCH` comment after FROM, `.dockerignore` with `*` (minimal context)
- Can optionally be nested under `aws/` if Terraform handles ECR build+push

## Directory Structure
```
aws-sample-eks-platform/
├── aws/
│   ├── modules/
│   │   ├── eks-cluster/          # EKS cluster + managed node groups
│   │   ├── eks-iam/              # Cluster role, node group role, Fargate role
│   │   ├── eks-oidc-iam/         # OIDC-based IRSA roles — instantiated per addon (EBS CSI, EFS CSI, ALB, autoscaler) with different policy ARNs
│   │   ├── eks-fargate/          # Fargate profile
│   │   ├── eks-karpenter/        # Karpenter IAM roles
│   │   └── ecr/                  # ECR repository management
│   └── envs/
│       └── eu-west-1/
│       ├── main.tf
│       ├── variables.tf
│       ├── terraform.tfvars
│       ├── locals.tf
│       ├── data.tf               # VPC, subnet, existing resource lookups
│       ├── eks.tf                # EKS cluster instantiation
│       ├── iam.tf                # IAM role instantiation
│       ├── fargate.tf
│       ├── efs.tf                # EFS filesystem
│       ├── ecr.tf
│       └── outputs.tf
├── flux/
│   ├── base/
│   │   ├── kustomization.yaml   # Lists all namespace YAML files
│   │   ├── sample-app-namespace.yaml
│   │   ├── aws-observability-namespace.yaml
│   │   └── fargate-namespace.yaml
│   ├── modules/
│   │   ├── aws-csi/             # gp3 StorageClass
│   │   ├── aws-load-balancer-controller/
│   │   ├── cluster-autoscaler/
│   │   ├── aws-logging/         # aws-logging ConfigMap for Fargate
│   │   └── sample-app/          # Demo nginx with LoadBalancer service
│   └── envs/
│       └── eu-west-1/
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
- `aws/envs/eu-west-1/main.tf`: provider config with `profile = "nlaclassic"`, `default_tags` block (`environment = "dev"`, `account-name = var.account_name`), local backend, required_version `~> 1.14.0`, AWS provider `6.31.0`
- `aws/envs/eu-west-1/variables.tf`: `account_name` (string), `region` (string, validated to `eu-west-1`), `environment` (string, default `dev`), `vpc_id` (string)
- `aws/envs/eu-west-1/terraform.tfvars`: `account_name = "nlaclassic"`, `region = "eu-west-1"`, `vpc_id = "vpc-00e377b27a8a29ba1"`
- `aws/envs/eu-west-1/locals.tf`: `env_prefix = "${var.account_name}-${var.region}"`, `eks_cluster_name = "${local.env_prefix}-eks"`
- `aws/envs/eu-west-1/data.tf`: look up existing VPC by `var.vpc_id`, subnets by `map-public-ip-on-launch` filter (private=false, public=true)
- `aws/modules/eks-iam/`: IAM cluster role (`AmazonEKSClusterPolicy`) and node group role (`AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`)
- `aws/modules/eks-cluster/`: wrap `terraform-aws-modules/eks/aws` v21.x — cluster creation with IRSA, public+private endpoints, coredns/kube-proxy/vpc-cni addons, security group rules (node-to-node all, egress all)
- `aws/envs/eu-west-1/eks.tf`: instantiate modules
- `aws/envs/eu-west-1/outputs.tf`: cluster endpoint, cluster name, OIDC provider ARN, kubeconfig update command
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
- `aws/envs/eu-west-1/fargate.tf`: instantiate with namespace selector (e.g., `fargate` namespace)

Flux (`flux/`):
- `flux/modules/aws-logging/`: `aws-logging` ConfigMap in `aws-observability` namespace for Fargate log routing to CloudWatch
- `flux/base/`: namespace YAML files — `aws-observability-namespace.yaml` (required for Fargate logging), `fargate-namespace.yaml` (Fargate target namespace), `sample-app-namespace.yaml` (for the demo app) — each as a separate file listed in `flux/base/kustomization.yaml`

### Phase 4: Expose Application via LoadBalancer Service
Flux (`flux/`):
- `flux/modules/sample-app/`: Deployment (nginx) + Service type LoadBalancer, kustomization.yaml
- Environment patch in `flux/envs/eu-west-1/`

Applications:
- `applications/sample-app/Dockerfile`: simple nginx container

### Phase 5: EBS/EFS Storage
Terraform (`aws/`):
- `aws/modules/eks-oidc-iam/`: reusable IRSA role module — instantiated once per addon with different `service_account_name`, `namespace`, and `policy_arns`. Called separately for EBS CSI driver (`AmazonEBSCSIDriverPolicy`) and EFS CSI driver (`AmazonEFSCSIDriverPolicy`)
- Install EBS CSI and EFS CSI as EKS addons via the cluster module (addon_version + service_account_role_arn)
- KMS key for EBS encryption (with policy allowing autoscaling service-linked role and cluster role)
- `aws/envs/eu-west-1/efs.tf`: create `aws_efs_file_system` (encrypted, lifecycle policy) + `aws_efs_mount_target` per private subnet + security group allowing NFS ingress from the cluster

Flux (`flux/`):
- `flux/modules/aws-csi/gp3.yaml`: gp3 StorageClass (default), encrypted, WaitForFirstConsumer (matching reference `flux-admin-v2/modules/aws-csi/gp3.yaml`)
- Example PVC manifest and StatefulSet with volumeClaimTemplates in `flux/modules/sample-app/` or a dedicated storage-demo module
- EFS: PersistentVolume + PVC pointing to EFS filesystem ID (filesystem created in `aws/envs/eu-west-1/efs.tf`, ID passed via Terraform output)

### Phase 6: Ingress Controller + ALB
Terraform (`aws/`):
- `aws/modules/eks-oidc-iam/`: IRSA role for AWS Load Balancer Controller (comprehensive policy from reference project: ec2, elasticloadbalancing, cognito, acm, waf, shield, iam:CreateServiceLinkedRole)

Flux (`flux/`):
- `flux/modules/aws-load-balancer-controller/`: Full ALB controller deployment — CRDs (IngressClassParams, TargetGroupBinding), ClusterRole, RoleBinding, Deployment, Service, IngressClass `alb`, webhook configuration (matching `flux-admin-v2/modules/aws-load-balancer-controller/`)
- Webhook TLS: use a self-signed certificate generated via a Job or static cert baked into the deployment manifests (avoiding full cert-manager dependency to keep the sample project lightweight; cert-manager can be added later if needed)
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
- Note: `local-exec` requires Docker to be running locally and won't work in CI without Docker-in-Docker. This is a pragmatic simplification for the sample project — the reference projects use GitHub Actions for image builds (`base-images/.github/workflows/`). A CI pipeline can be added later
- `aws/envs/eu-west-1/ecr.tf`: create repositories for sample-app (and future services)
- Node IAM roles already have `AmazonEC2ContainerRegistryReadOnly` from Phase 2

Flux (`flux/`):
- Update sample-app deployment image to use ECR repository URI

Applications:
- `applications/sample-app/Dockerfile` + `.dockerignore` — the source directory that the ecr module hashes and builds

## Backlog

Status: **PENDING** | **IN PROGRESS** | **DONE**

- IN PROGRESS — Phase 1: Foundation — EKS Cluster + IAM + kubectl Access
  - DONE — Setting up AWS EKS
  - DONE — IAM cluster role
  - DONE — IAM node group role
  - PENDING — Ensure AWS EKS cluster is accessible through kubectl CLI
- DONE — Phase 2: Managed Node Groups
  - DONE — Create managed node groups
- DONE — Phase 3: Fargate Profile + Logging
  - DONE — Create IAM role for Fargate profile
  - DONE — Add Fargate profile to EKS
  - DONE — Add aws-logging ConfigMap
  - DONE — Add namespace YAMLs (aws-observability, fargate, sample-app)
  - DONE — Add bin/ scripts (build.sh, validate.sh, tf-plan.sh)
- DONE — Phase 4: Sample Application + LoadBalancer Service
  - DONE — Copy python-fastapi-demo-docker source to applications/sample-app/
  - DONE — Create Dockerfile with SHA256-pinned python:3.9-slim-buster base image
  - DONE — Add sample-app ECR repository
  - DONE — Create Flux manifests (Deployment, LoadBalancer Service, Postgres StatefulSet, Secret, ConfigMap)
  - DONE — Wire sample-app module into dev environment kustomization
- PENDING — Phase 5: EBS/EFS Storage
  - PENDING — IAM configuration to use EBS as storage
  - PENDING — Install and configure CSI Driver
  - PENDING — Persistent storage with PVC EBS CSI Driver
  - PENDING — Persistent storage with ClaimTemplates
  - PENDING — Configurations to use EFS PersistentVolumes
- PENDING — Phase 6: Ingress Controller + ALB
  - PENDING — IAM Policy for ALB
  - PENDING — Deploying ALB Ingress Controller Resources
  - PENDING — Deploying ALB Ingress Controller to Route External Traffic
- PENDING — Phase 7: Scaling — Cluster Autoscaler + Karpenter
  - PENDING — Cluster Autoscaler for NodeGroups / Karpenter
  - PENDING — IAM Policy and Role for Cluster AutoScaler
  - PENDING — Observability for Cluster Autoscaler
- DONE — Phase 8: ECR Integration
  - DONE — Create ECR module (scanning, lifecycle, local-exec build/push)
  - DONE — Add nats and nats-box Dockerfiles (from base-images reference)
  - DONE — Instantiate ECR repos for nats and nats-box
  - DONE — Add kgateway-*, keda-* images (from base-images reference)
  - DONE — Add prometheus-* images (from base-images reference)
  - DONE — Add sealed-secrets-controller image (from base-images reference)

## Execution Order
Phases were executed out of order based on user direction:
1. Phases 1-3 (Foundation, Node Groups, Fargate) — sequential
2. Phase 8 (ECR Integration) — done before Phases 4-7
3. Phase 4 (Sample Application + LoadBalancer) — done after Phase 8

Each phase is independently deployable/undoable. Terraform `destroy` tears down AWS resources; `kubectl delete -k` removes Flux resources.

Phases are executed one at a time. After each phase, a commit message is suggested and execution pauses until the user commits and gives the go-ahead.

## Notes
- The `nlaclassic` AWS profile has `region = eu-west-1` only — no `role_arn` or `source_profile`. Credentials likely come from `~/.aws/credentials`, env vars, or SSO. We use `profile = "nlaclassic"` in the provider as-is
- VPC `vpc-00e377b27a8a29ba1` (nla-vpc-dev-2, 10.16.0.0/16) with 3 private + 3 public subnets across eu-west-1a/b/c. Subnets lack Kubernetes tags so we use `map-public-ip-on-launch` filter to distinguish private/public
- Security groups are created fresh per the requirements
- We keep the plan simple for a sample/reference project — no multi-environment complexity initially, just `dev` environment targeting `eu-west-1`
- Divergences from reference projects are documented inline (community EKS module vs custom, `local-exec` Docker builds vs GitHub Actions CI, self-signed webhook certs vs cert-manager)
