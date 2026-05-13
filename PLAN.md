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
│   │   ├── eks-iam/              # Cluster role, node group role
│   │   ├── eks-oidc-iam/         # OIDC-based IRSA roles — reusable, instantiated per addon
│   │   ├── eks-fargate/          # Fargate profile
│   │   ├── eks-karpenter/        # Karpenter IAM roles
│   │   └── ecr/                  # ECR repository management
│   └── envs/
│       └── eu-west-1/
│           ├── main.tf
│           ├── variables.tf
│           ├── terraform.tfvars
│           ├── locals.tf
│           ├── data.tf           # VPC, subnet, existing resource lookups
│           ├── eks.tf            # EKS cluster instantiation
│           ├── iam.tf            # IAM role instantiation
│           ├── fargate.tf
│           ├── alb.tf            # ALB controller IRSA role + IAM policy
│           ├── route53.tf        # Route53 zone + conditional ALB alias record
│           ├── efs.tf            # EFS filesystem (Phase 5)
│           ├── ecr.tf
│           └── outputs.tf
├── flux/
│   ├── base/
│   │   ├── kustomization.yaml   # Lists all namespace YAML files
│   │   ├── sample-app-namespace.yaml
│   │   ├── aws-observability-namespace.yaml
│   │   ├── cert-manager-namespace.yaml
│   │   ├── fargate-namespace.yaml
│   │   └── kgateway-namespace.yaml
│   ├── modules/
│   │   ├── aws-csi/             # gp3 StorageClass (Phase 5)
│   │   ├── aws-load-balancer-controller/  # CRDs, RBAC, Deployment, Webhooks, IngressClass
│   │   ├── cert-manager/        # cert-manager v1.19.2 CRDs, Deployments, Webhooks, self-signing ClusterIssuer
│   │   ├── cluster-autoscaler/  # Phase 7
│   │   ├── aws-logging/         # aws-logging ConfigMap for Fargate
│   │   ├── cloudnative-pg/      # CloudNativePG operator v1.28.1 (CRDs, RBAC, Deployment, Webhooks)
│   │   ├── kgateway/            # Gloo Gateway: CRDs, control plane, Envoy proxy
│   │   └── sample-app/          # FastAPI app + CloudNativePG Cluster CR (ClusterIP service)
│   └── envs/
│       └── eu-west-1/
│           ├── kustomization.yaml
│           ├── cert-manager/     # Environment overlay
│           ├── cluster-information-configmap.yaml
│           └── kgateway/        # GatewayClass, Gateway, VirtualService, ALB Ingress
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
- `aws/envs/eu-west-1/eks.tf`: Fargate profiles for 3 namespaces:
  - `fargate` — general-purpose Fargate namespace
  - `kgateway` — all kgateway components (gloo, discovery, gateway-proxy) run on Fargate as they are stateless Deployments with no hostNetwork/privileged requirements
  - `sample-app` — only FastAPI pods (label `app: fastapi-app`) run on Fargate; Postgres StatefulSet stays on managed nodes because Fargate does not support EBS volumes

Flux (`flux/`):
- `flux/modules/aws-logging/`: `aws-logging` ConfigMap in `aws-observability` namespace for Fargate log routing to CloudWatch
- `flux/base/`: namespace YAML files — `aws-observability-namespace.yaml` (required for Fargate logging), `fargate-namespace.yaml` (Fargate target namespace), `sample-app-namespace.yaml` (for the demo app) — each as a separate file listed in `flux/base/kustomization.yaml`
- `flux/modules/sample-app/kustomization.yaml`: `namespace: sample-app` set to ensure all sample-app resources deploy to the correct namespace (required for Fargate profile matching)

### Phase 4: Sample Application + LoadBalancer Service + PostgreSQL with Replication
Flux (`flux/`):
- `flux/modules/sample-app/`: Deployment (nginx) + Service type LoadBalancer, kustomization.yaml
- Environment patch in `flux/envs/eu-west-1/`

Applications:
- `applications/sample-app/Dockerfile`: simple nginx container

#### Phase 4b: Upgrade PostgreSQL to Bitnami with Replication
Replace the simple single-instance Postgres 13 StatefulSet with bitnami `postgresql` chart (architecture: `replication`) providing a primary + read replica(s). This is simpler than full HA (postgresql-ha with Repmgr+Pgpool) while still providing redundancy.

Source: `/Users/fawadmazhar/github/codes/k8s-references/charts/bitnami/postgresql/` (chart v17.1.0, app v17.6.0)

Approach: Render the Helm chart with `helm template` using custom values, then adapt rendered manifests for Flux/Kustomize.

Terraform (`aws/`):
- `aws/envs/eu-west-1/ecr.tf`: Add ECR repository for `bitnami/postgresql` image (v17.6.0)

Applications:
- `applications/postgresql/Dockerfile`: FROM `docker.io/bitnami/postgresql:17.6.0-debian-12-r4` (SHA256-pinned)

Flux (`flux/`):
- Replace `flux/modules/sample-app/postgres.yaml` with bitnami-rendered manifests:
  - Primary StatefulSet (1 replica) with volumeClaimTemplates, health checks, bitnami env vars
  - Read replica StatefulSet (1 replica) with streaming replication from primary
  - Primary Service (ClusterIP) + Headless Service
  - Read replica Service (ClusterIP) + Headless Service
  - ConfigMap for postgresql.conf customization
  - Secret updated with bitnami-compatible credential format (postgres password, replication user/password)
- Update `flux/modules/sample-app/secret.yaml`: connection string points to primary service
- Preserve init script (`db-init-configmap.yaml`) — adapted for bitnami's init mechanism (`/docker-entrypoint-initdb.d/`)
- Image references point to project ECR (`228904764948.dkr.ecr.eu-west-1.amazonaws.com/nlaclassic-eu-west-1/postgresql:17.6.0`)

Key details:
- Primary handles reads+writes; read replica(s) handle read-only queries via separate service
- FastAPI app connects to primary service (same pattern as current `db` service, just renamed)
- PostgreSQL native streaming replication (no Repmgr, no Pgpool)
- Manual failover if primary fails (acceptable for sample project)
- Still requires EBS CSI driver (Phase 5) for PVCs — Postgres cannot run on Fargate

#### Phase 4c: Replace Bitnami PostgreSQL with CloudNativePG
Replace the bitnami PostgreSQL StatefulSets (460 lines of hand-managed YAML) with CloudNativePG operator (CNCF Sandbox project). CloudNativePG manages PostgreSQL natively in Kubernetes via a `Cluster` CRD, providing automatic failover, synchronous replication, and rolling updates — all without external tools like Repmgr or Patroni.

Source: `/Users/fawadmazhar/github/codes/k8s-references/cloudnative-pg` (v1.28.1)

Flux (`flux/`):
- `flux/modules/cloudnative-pg/`: CNPG operator v1.28.1 — CRDs (10), ServiceAccount, ClusterRoles, ClusterRoleBindings, Deployment, Service, ConfigMap (default monitoring queries), Mutating/Validating Webhooks. Operator image: `ghcr.io/cloudnative-pg/cloudnative-pg:1.28.1`
- `flux/base/cnpg-system-namespace.yaml`: Namespace for CNPG operator
- Replace `flux/modules/sample-app/postgres.yaml` with a single CNPG `Cluster` CR (~40 lines) replacing ~460 lines of bitnami manifests:
  - 3 instances (1 primary + 2 replicas) with automatic failover
  - PostgreSQL image: `ghcr.io/cloudnative-pg/postgresql:18.3`
  - Bootstrap: database `bookstore`, owner `bookdbadmin`, init SQL via `postInitApplicationSQLRefs` referencing existing `db-init-script` ConfigMap
  - Storage: gp3, 2Gi
  - Unsupervised primary update strategy (auto-switchover during updates)
  - Pod anti-affinity to spread across nodes
- Update `flux/modules/sample-app/secret.yaml`:
  - FastAPI connection string points to `postgresql-rw` (CNPG auto-generated read-write service)
  - Add `postgresql-app-user` Secret (kubernetes.io/basic-auth) for CNPG bootstrap
  - Add `postgresql-superuser` Secret (kubernetes.io/basic-auth) for superuser access
- Keep `db-init-configmap.yaml` (referenced by Cluster CR's `postInitApplicationSQLRefs`)
- Wire `cloudnative-pg` module into `flux/envs/eu-west-1/kustomization.yaml`

Terraform (`aws/`):
- Remove `postgresql` ECR repository (no longer needed — CNPG uses its own PostgreSQL image from ghcr.io)

Applications:
- Remove `applications/postgresql/` directory (Dockerfile no longer needed)

Key details:
- CNPG auto-generates services: `postgresql-rw` (primary), `postgresql-ro` (replicas), `postgresql-r` (all)
- CNPG auto-generates secrets, TLS certs, PDBs, ServiceAccount
- Automatic failover: operator detects primary failure, promotes best replica in seconds
- 3 instances provides true HA with quorum — no single point of failure
- No ECR mirroring needed — uses official CNPG PostgreSQL image from ghcr.io
- Operator watches all namespaces — Cluster CR in `sample-app` namespace managed by operator in `cnpg-system`
- Still requires EBS CSI driver (Phase 5) for PVCs — Postgres cannot run on Fargate

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

### Phase 6: Ingress Controller + ALB + kgateway + cert-manager + Domain/SSL
Terraform (`aws/`):
- `aws/modules/eks-oidc-iam/`: Reusable IRSA module — creates IAM role with OIDC trust policy for a given service account + namespace. Generic and instantiated per addon
- `aws/envs/eu-west-1/alb.tf`: Instantiate IRSA for ALB controller with comprehensive IAM policy (14 statements: ec2, elasticloadbalancing, cognito, acm, waf, shield, iam:CreateServiceLinkedRole). Policy from `aws-landingzone` reference
- `aws/envs/eu-west-1/route53.tf`: Route53 hosted zone for `code-si.com` + conditional A record alias for `books.code-si.com` → ALB (gated by `alb_deployed` variable — set to `true` after ALB exists)

Flux (`flux/`):
- `flux/modules/cert-manager/`: cert-manager v1.19.2 — CRDs (6), Deployments (controller, webhook, cainjector), RBAC, Services, ValidatingWebhookConfiguration, MutatingWebhookConfiguration, self-signing ClusterIssuer. Images from project ECR. Namespace resource removed (managed in `flux/base/`)
- `flux/base/cert-manager-namespace.yaml`: Namespace for cert-manager
- `flux/envs/eu-west-1/cert-manager/`: Environment overlay with `namespace: cert-manager`
- `flux/modules/aws-load-balancer-controller/`: Full ALB controller deployment — CRDs (IngressClassParams, TargetGroupBinding), ServiceAccount with IRSA annotation, ClusterRole, RoleBinding, Deployment, Service, IngressClass `alb`, webhook configuration. Image: `public.ecr.aws/eks/aws-load-balancer-controller:v2.12.0`. Adapted from `flux-admin-v2` reference. Requires cert-manager for webhook TLS
- `flux/envs/eu-west-1/cluster-information-configmap.yaml`: ConfigMap in kube-system with cluster-name, aws-region, aws-vpc-id (read by ALB controller deployment)
- `flux/modules/kgateway/`: Gloo Gateway — CRDs (Gateway API + Gloo custom resources), control plane (gloo, discovery, gateway-proxy deployments), RBAC, ConfigMaps, Settings. Images from ECR (`nlaclassic-eu-west-1/kgateway-*:1.20.9`). Adapted from `flux-admin-v2/modules/kgateway/`
- `flux/base/kgateway-namespace.yaml`: Namespace for kgateway components
- `flux/envs/eu-west-1/kgateway/`: Environment overlay — GatewayClass (`solo.io/gloo-gateway`), Gateway (HTTP listener port 80), Gloo Gateway (binds Envoy to port 8080), VirtualService routing `books.code-si.com/*` to `sample-app-fastapi-service-80` upstream, ALB Ingress (internet-facing, HTTPS with ACM cert, HTTP→HTTPS redirect, host `books.code-si.com`, routes to gateway-proxy)
- `flux/modules/sample-app/service.yaml`: Changed from LoadBalancer to ClusterIP (traffic now routed via kgateway)

Traffic flow: Client → `books.code-si.com` (Route53) → AWS ALB (HTTPS, ACM cert) → gateway-proxy (Envoy, HTTP) → VirtualService routing → sample-app Service (ClusterIP) → FastAPI pods

### Phase 7: Scaling — Cluster Autoscaler (Karpenter deferred)
Terraform (`aws/`):
- `aws/envs/eu-west-1/autoscaler.tf`: IRSA role for cluster-autoscaler via `eks-oidc-iam` module. IAM policy: autoscaling describe (5 actions), ec2 describe (3 actions), eks:DescribeNodegroup as read-only; autoscaling:SetDesiredCapacity + TerminateInstanceInAutoScalingGroup scoped by `k8s.io/cluster-autoscaler/enabled` tag condition
- `aws/envs/eu-west-1/ecr.tf`: cluster-autoscaler ECR repository (v1.34.2)

Applications:
- `applications/cluster-autoscaler/Dockerfile`: FROM `registry.k8s.io/autoscaling/cluster-autoscaler:v1.34.2` (SHA256-pinned, from `base-images` reference)

Flux (`flux/`):
- `flux/modules/cluster-autoscaler/autoscaler-deployment.yaml`: Deployment in kube-system, 1 replica, `role: platform` nodeSelector, ECR image, `--cloud-provider=aws`, `--expander=least-waste`, `--balance-similar-node-groups=true`, `--node-group-auto-discovery` by ASG tags, `readOnlyRootFilesystem`, `runAsUser: 10070`. Cluster name from existing `cluster-information` ConfigMap (reused from ALB controller, avoids duplicate ConfigMap)
- `flux/modules/cluster-autoscaler/autoscaler-rbac.yaml`: ServiceAccount (IRSA-annotated), ClusterRole, Role (kube-system), ClusterRoleBinding, RoleBinding — from `flux-admin-v2` reference
- Observability: Prometheus scrape annotations on autoscaler pods (`prometheus.io/scrape: "true"`, `prometheus.io/port: "8085"`)

Karpenter deferred to a future phase per user direction.

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
  - DONE — Add Fargate profile for kgateway namespace (all components: gloo, discovery, gateway-proxy)
  - DONE — Add Fargate profile for sample-app namespace (FastAPI only — label selector `app: fastapi-app`; Postgres excluded — Fargate does not support EBS)
  - DONE — Set `namespace: sample-app` on sample-app module kustomization for Fargate profile matching
- DONE — Phase 4: Sample Application + LoadBalancer Service + PostgreSQL with Replication
  - DONE — Copy python-fastapi-demo-docker source to applications/sample-app/
  - DONE — Create Dockerfile with SHA256-pinned python:3.9-slim-buster base image
  - DONE — Add sample-app ECR repository
  - DONE — Create Flux manifests (Deployment, LoadBalancer Service, Postgres StatefulSet, Secret, ConfigMap)
  - DONE — Wire sample-app module into dev environment kustomization
  - DONE — Upgrade PostgreSQL to bitnami with replication (primary + read replica)
  - DONE — Add ECR repository for bitnami/postgresql image (v18.3.0)
  - DONE — Add postgresql Dockerfile (bitnami/postgresql:latest, SHA256-pinned)
  - DONE — Replace simple postgres.yaml with bitnami-rendered manifests (primary StatefulSet, read replica StatefulSet, Services, PDBs, ServiceAccount, Secret)
  - DONE — Update secret with bitnami-compatible credential format + init script simplified for bitnami
  - DONE — Replace bitnami PostgreSQL with CloudNativePG operator (v1.28.1)
  - DONE — Add CNPG operator module (CRDs, RBAC, Deployment, Webhooks)
  - DONE — Add cnpg-system namespace
  - DONE — Replace 460-line bitnami manifests with 40-line CNPG Cluster CR (3 instances, auto failover)
  - DONE — Update secrets for CNPG (app-user + superuser basic-auth format)
  - DONE — Update FastAPI connection string to postgresql-rw (CNPG auto-generated service)
  - DONE — Remove bitnami postgresql ECR repo and Dockerfile (CNPG uses ghcr.io image)
- DONE — Phase 5: EBS/EFS Storage
  - DONE — IRSA for EBS CSI driver (AmazonEBSCSIDriverPolicy)
  - DONE — IRSA for EFS CSI driver (AmazonEFSCSIDriverPolicy)
  - DONE — EBS CSI driver EKS addon (v1.43.0-eksbuild.1)
  - DONE — EFS CSI driver EKS addon (v2.2.0-eksbuild.1)
  - DONE — EFS filesystem with encryption + mount targets in private subnets + NFS security group
  - DONE — gp3 StorageClass (default, encrypted, WaitForFirstConsumer)
  - DONE — EFS StorageClass
  - DONE — Wire aws-csi module into environment kustomization
- DONE — Phase 6: Ingress Controller + ALB + kgateway + cert-manager + Domain/SSL
  - DONE — Create reusable IRSA module (aws/modules/eks-oidc-iam/)
  - DONE — ALB controller IRSA role with full IAM policy (aws/envs/eu-west-1/alb.tf)
  - DONE — ALB controller Flux manifests (CRDs, RBAC, ServiceAccount, Deployment, Webhooks, IngressClass)
  - DONE — cluster-information ConfigMap for ALB controller
  - DONE — kgateway base module (CRDs, control plane, Envoy proxy — from flux-admin-v2 reference)
  - DONE — kgateway environment overlay (GatewayClass, Gateway, VirtualService, ALB Ingress)
  - DONE — VirtualService routing / to sample-app via kgateway
  - DONE — Change sample-app service from LoadBalancer to ClusterIP
  - DONE — cert-manager v1.19.2 module (CRDs, controller, webhook, cainjector, self-signing ClusterIssuer)
  - DONE — cert-manager ECR repos (controller, webhook, cainjector) + Dockerfiles
  - DONE — Route53 hosted zone for code-si.com + conditional ALB alias for books.code-si.com
  - DONE — ALB Ingress updated: HTTPS with ACM cert, HTTP→HTTPS redirect, host books.code-si.com
  - DONE — VirtualService updated: domain books.code-si.com instead of wildcard
- DONE — Phase 7: Scaling — Cluster Autoscaler (Karpenter deferred)
  - DONE — Cluster Autoscaler IRSA role (aws/envs/eu-west-1/autoscaler.tf)
  - DONE — Cluster Autoscaler ECR repository + Dockerfile (v1.34.2, from base-images reference)
  - DONE — Cluster Autoscaler Flux module (Deployment, ServiceAccount, RBAC — from flux-admin-v2 reference)
  - DONE — Prometheus scrape annotations for observability
  - DONE — Wired into flux/envs/eu-west-1/kustomization.yaml
  - PENDING — Karpenter (deferred to future phase)
- DONE — Phase 8: ECR Integration
  - DONE — Create ECR module (scanning, lifecycle, local-exec build/push)
  - DONE — Add nats and nats-box Dockerfiles (from base-images reference)
  - DONE — Instantiate ECR repos for nats and nats-box
  - DONE — Add kgateway-*, keda-* images (from base-images reference)
  - DONE — Add prometheus-* images (from base-images reference)
  - DONE — Add sealed-secrets-controller image (from base-images reference)
  - DONE — Add cert-manager-controller, cert-manager-webhook, cert-manager-cainjector images (v1.19.2, from base-images reference)

## Execution Order
Phases were executed out of order based on user direction:
1. Phases 1-3 (Foundation, Node Groups, Fargate) — sequential
2. Phase 8 (ECR Integration) — done before Phases 4-7
3. Phase 4 (Sample Application + LoadBalancer) — done after Phase 8
4. Phase 6 (ALB + kgateway) — done before Phase 5 and 7
5. Phase 4b (PostgreSQL bitnami replication) + Phase 5 (EBS/EFS Storage) — done together
6. Phase 4c (CloudNativePG) — replaces bitnami PostgreSQL with CNPG operator
7. Phase 7 (Cluster Autoscaler) — Karpenter deferred

Each phase is independently deployable/undoable. Terraform `destroy` tears down AWS resources; `kubectl delete -k` removes Flux resources.

Phases are executed one at a time. After each phase, a commit message is suggested and execution pauses until the user commits and gives the go-ahead.

## Notes
- The `nlaclassic` AWS profile has `region = eu-west-1` only — no `role_arn` or `source_profile`. Credentials likely come from `~/.aws/credentials`, env vars, or SSO. We use `profile = "nlaclassic"` in the provider as-is
- VPC `vpc-00e377b27a8a29ba1` (nla-vpc-dev-2, 10.16.0.0/16) with 3 private + 3 public subnets across eu-west-1a/b/c. Subnets lack Kubernetes tags so we use `map-public-ip-on-launch` filter to distinguish private/public
- Security groups are created fresh per the requirements
- We keep the plan simple for a sample/reference project — no multi-environment complexity initially, just `dev` environment targeting `eu-west-1`
- Divergences from reference projects are documented inline (community EKS module vs custom, `local-exec` Docker builds vs GitHub Actions CI, self-signed webhook certs vs cert-manager)
- cert-manager v1.19.2 installed as prerequisite for ALB controller webhook TLS. Images mirrored to project ECR from quay.io/jetstack (SHA256-pinned in Dockerfiles)
- ALB controller uses `public.ecr.aws/eks/aws-load-balancer-controller:v2.12.0` (public ECR). Can be mirrored to project ECR for production use
- Domain `code-si.com` with ACM cert in eu-west-1 (`arn:aws:acm:eu-west-1:228904764948:certificate/6868d04e-52c9-4b60-a374-1b028fa701eb`). Route53 ALB record gated by `alb_deployed` variable (set to `true` after ALB exists)
- kgateway manifests adapted from `flux-admin-v2` reference — namespace changed from `support` to `kgateway`, images point to project ECR, replicas scaled to 1 for sample project
- Fargate scheduling: kgateway runs entirely on Fargate (all 3 components are stateless Deployments with no hostNetwork/privileged/DaemonSet constraints). Sample-app FastAPI runs on Fargate; PostgreSQL (CloudNativePG) stays on managed nodes (Fargate does not support EBS PersistentVolumeClaims — only EFS is supported). CNPG operator runs in `cnpg-system` namespace on managed nodes
- PostgreSQL: Using CloudNativePG operator v1.28.1 (CNCF Sandbox project) — replaces bitnami StatefulSets with a single `Cluster` CRD. 3 instances (1 primary + 2 replicas) with automatic failover, synchronous replication, and rolling updates. PostgreSQL image `ghcr.io/cloudnative-pg/postgresql:18.3`. Source: `/Users/fawadmazhar/github/codes/k8s-references/cloudnative-pg/`. Previous bitnami approach replaced due to lack of automatic failover and high manifest complexity (460 lines vs 40 lines)
- EBS/EFS CSI: AWS managed policies (`AmazonEBSCSIDriverPolicy`, `AmazonEFSCSIDriverPolicy`) with IRSA. CSI drivers installed as EKS addons (conditionally, via version+role_arn variables). EFS filesystem encrypted with lifecycle policy (transition to IA after 7 days), mount targets in all private subnets, NFS security group referencing EKS node SG
- Cluster Autoscaler: v1.34.2 from `base-images` reference, image mirrored to project ECR. Runs on `platform` node group (`role: platform`). Uses `cluster-information` ConfigMap (shared with ALB controller) for cluster name. ASG auto-discovery via existing `k8s.io/cluster-autoscaler/enabled` + `k8s.io/cluster-autoscaler/<cluster-name>` tags on managed node groups. Write permissions (SetDesiredCapacity, TerminateInstanceInAutoScalingGroup) scoped by tag condition
- Terraform plan: ~108 resources (17 ECR repos, EKS cluster with 5 addons, 3 Fargate profiles, 2 node groups, IAM roles incl. cluster-autoscaler IRSA, Route53 zone, EFS filesystem + mount targets + SG)

## Deployment

### Prerequisites
- AWS CLI configured with `nlaclassic` profile
- Terraform `~> 1.14.0`
- kubectl
- Docker running locally (for ECR image builds)
- kustomize (for validation)

### Virgin Deployment (First Time)

A fresh deployment is a two-phase process because the Route53 ALB alias record depends on the ALB existing, which is created by the K8s ALB controller after it processes the Ingress resource.

**Step 1 — Terraform (infrastructure + ECR images)**

```bash
cd aws/envs/eu-west-1

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

This creates ~108 resources: IAM roles (incl. cluster-autoscaler IRSA), EKS cluster (~15-20 min), node groups, Fargate profiles, ECR repos (builds+pushes all 18 images), Route53 zone, EFS filesystem, CSI driver addons. The `alb_deployed` variable defaults to `false`, so no Route53 ALB record is created yet.

**Step 2 — Configure kubectl**

```bash
aws eks update-kubeconfig --name nlaclassic-eu-west-1-eks --region eu-west-1 --profile nlaclassic
kubectl get nodes   # verify nodes are Ready
```

**Step 3 — Deploy Kubernetes resources (ordered)**

Resources must be applied in order due to dependencies (CRDs before instances, cert-manager before ALB controller).

```bash
# 1. Base namespaces
kubectl apply -k flux/base/

# 2. StorageClasses (gp3 default + EFS)
kubectl apply -k flux/modules/aws-csi/

# 3. Fargate logging
kubectl apply -k flux/modules/aws-logging/

# 4. cert-manager (wait for pods Ready — ALB controller depends on its webhooks)
kubectl apply -k flux/envs/eu-west-1/cert-manager/
kubectl -n cert-manager rollout status deployment/cert-manager
kubectl -n cert-manager rollout status deployment/cert-manager-webhook
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector

# 5. Cluster Autoscaler
kubectl apply -k flux/modules/cluster-autoscaler/
kubectl -n kube-system rollout status deployment/cluster-autoscaler

# 6. ALB controller (depends on cert-manager for webhook TLS)
kubectl apply -k flux/modules/aws-load-balancer-controller/
kubectl apply -f flux/envs/eu-west-1/cluster-information-configmap.yaml
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller

# 6. CloudNativePG operator (wait for controller Ready — manages PostgreSQL Cluster CRs)
kubectl apply -k flux/modules/cloudnative-pg/
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager

# 7. kgateway (API gateway + Ingress → creates ALB)
kubectl apply -k flux/envs/eu-west-1/kgateway/
kubectl -n kgateway rollout status deployment/gloo
kubectl -n kgateway rollout status deployment/gateway-proxy

# 8. Sample app (FastAPI + CloudNativePG PostgreSQL cluster)
kubectl apply -k flux/modules/sample-app/
kubectl -n sample-app rollout status deployment/fastapi-deployment
# Wait for PostgreSQL cluster to be ready (3 instances)
kubectl -n sample-app wait --for=condition=Ready cluster/postgresql --timeout=300s
```

**Step 4 — Verify ALB is created**

Wait for the ALB controller to provision the load balancer from the Ingress resource:

```bash
kubectl -n kgateway get ingress kgateway-alb
# Wait until ADDRESS column shows an ALB DNS name
```

**Step 5 — Terraform phase 2 (Route53 ALB record)**

Once the ALB exists, create the Route53 alias record:

```bash
cd aws/envs/eu-west-1

terraform plan -var="alb_deployed=true" -out=tfplan
terraform apply tfplan
```

This creates the `books.code-si.com` → ALB alias record.

**Step 6 — DNS configuration**

If `code-si.com` is registered with an external registrar, update the NS records at the registrar to point to the Route53 nameservers:

```bash
terraform output route53_nameservers
```

Copy the 4 nameserver values to the domain registrar's NS records.

**Step 7 — Verify end-to-end**

```bash
curl https://books.code-si.com/
# Should return FastAPI sample app response
```

Traffic flow: `books.code-si.com` → Route53 → ALB (HTTPS, TLS 1.3) → gateway-proxy (HTTP) → VirtualService → FastAPI

### Normal Deployments (Subsequent Changes)

For changes after the initial setup:

**Terraform changes (AWS resources)**

```bash
cd aws/envs/eu-west-1

terraform plan -var="alb_deployed=true" -out=tfplan
# Review the plan
terraform apply tfplan
```

Note: always pass `-var="alb_deployed=true"` after the ALB exists, otherwise Terraform will try to destroy the Route53 ALB record.

**Kubernetes changes (Flux manifests)**

```bash
# Validate first
kustomize build flux/envs/eu-west-1 > /dev/null

# Apply the specific module that changed
kubectl apply -k flux/modules/<changed-module>/
# or apply the full environment
kubectl apply -k flux/envs/eu-west-1/
```

**Application image updates**

When updating application code or Dockerfiles:

1. Update the `image_tag` in `aws/envs/eu-west-1/ecr.tf`
2. Run `terraform apply` — the ECR module detects source hash changes and rebuilds/pushes
3. Update the image tag in the corresponding Flux deployment manifest
4. Apply the Kubernetes change: `kubectl apply -k flux/modules/<app>/`

### Teardown

Reverse order of deployment:

```bash
# 1. Remove Kubernetes resources
kubectl delete -k flux/envs/eu-west-1/

# 2. Destroy Terraform resources
cd aws/envs/eu-west-1
terraform destroy -var="alb_deployed=true"
```

Note: EKS cluster deletion takes ~10-15 minutes. ECR repos with images require `force_delete = true` (already configured in the ECR module).
