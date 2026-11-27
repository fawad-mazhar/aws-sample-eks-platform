# AWS Sample EKS Platform

## System Design

Creation order matters because the platform combines Terraform-managed AWS
resources, Kubernetes CRDs, external controllers and Terraform outputs copied
into the cluster. Kustomize document order is not a readiness guarantee:
wait for each dependency's readiness gate before creating its consumers.

<details>
  <summary>End-to-end dependency graph</summary>

  ```mermaid
  flowchart TD
    A[Inputs and account checks] --> B[Terraform phase 1]
    B --> C[EKS control plane]
    B --> D[ECR repositories and images]
    B --> E[IAM, EFS, Pod Identity and network rules]
    C --> F[VPC CNI and Pod Identity Agent]
    F --> G[Managed node groups and Fargate profiles]
    G --> H[Post-compute EKS add-ons]
    H --> I[Configure kubeconfig and wait for Ready nodes]
    I --> J[CRD bootstrap and wait for Established]
    J --> K[Base namespaces]
    K --> L[StorageClasses and logging]
    L --> M[Terraform-derived ConfigMaps]
    M --> N[Foundation controllers]
    N --> O[ALB controller]
    O --> P[kgateway and Ingress]
    N --> Q[CloudNativePG operator]
    Q --> R[Sample application and PostgreSQL Cluster]
    P --> R
    P --> S[Wait for healthy ALB targets]
    S --> T[Terraform phase 2: Route53 alias]
    R --> U[End-to-end HTTPS verification]
    T --> U
  ```

  The arrows are readiness dependencies, not only object references. Some
  Terraform branches and sibling Flux Kustomizations can run in parallel, but
  no resource should be advanced across a stated readiness gate.

  Non-negotiable rules:

  1. Load the git-ignored `.env` before Terraform, AWS or rendering commands.
  2. Do not deploy custom-domain manifests without a regional ACM certificate
     and the domain variables.
  3. Install VPC CNI and the EKS Pod Identity Agent before compute.
  4. Establish CRDs before applying custom resources of those kinds.
  5. Use server-side apply for the CRD bundle because several vendored CRDs
     exceed kubectl's client-side annotation limit.
  6. Create an ALB Ingress only after the ALB controller is ready.
  7. Create a CloudNativePG `Cluster` only after its operator is ready.
  8. Create Karpenter `NodePool` and `EC2NodeClass` resources only after the
     Karpenter controller and CRDs are ready.
  9. Create the Route53 ALB alias only after a healthy ALB exists and pass
     `alb_deployed=true`.
  10. When reusing a Route53 hosted zone, never replace the registrar's
      delegated nameservers with nameservers from a second zone.
  11. For Flux, commit and push to `main` before applying the Flux bootstrap;
      the configured `GitRepository` does not read `dev` or local changes.
</details>

<details>
  <summary>Namespace ownership model</summary>

  Namespaces describe ownership and lifecycle, while component and Kubernetes
  resource names continue to identify the deployed technology.

  | Namespace | Category | Contents |
  | --- | --- | --- |
  | `flux-system` | platform system | Flux controllers, sources and reconciliation configuration |
  | `aws-observability` | platform integration | EKS Fargate logging configuration |
  | `cert-manager` | platform system | cert-manager controllers and webhook |
  | `cnpg-system` | platform system | CloudNativePG operator; application databases remain with their consumers |
  | `gateway-system` | shared capability | AWS Load Balancer Controller, kgateway and ingress resources |
  | `autoscaling-system` | shared capability | KEDA, Cluster Autoscaler and Karpenter |
  | `observability` | shared capability | Prometheus and future monitoring components |
  | `messaging` | shared data capability | NATS |
  | `object-storage` | shared data capability | Garage |
  | `apps-demo` | application domain | FastAPI and its CloudNativePG database |
  | `default`, `kube-*` | reserved | Kubernetes/EKS infrastructure only; ordinary workloads do not run here |

  The `nats`, `garage`, `kgateway`, `sample-app`, `keda` and controller Flux
  Kustomizations retain those names because they identify modules and
  technologies. Their resources are assigned to the capability namespaces
  above. This keeps GitOps composition names stable without coupling them to
  deployment ownership.

  The generic Fargate profile is intentionally absent. The `gateway-system`
  profile selects only kgateway pods labeled
  `app.kubernetes.io/part-of=gateway-system`, while the `apps-demo` profile
  selects only `app=fastapi-app` pods. The ALB controller is managed on EC2
  nodes and is not selected by the gateway Fargate profile.

  `kube-system` is still used where Kubernetes requires it, including EBS/EFS
  CSI service accounts, cert-manager leader-election RBAC and KEDA's binding
  to the built-in HPA service account.
</details>

<details>
  <summary>Terraform resource creation order</summary>

  Terraform determines the exact graph from references and `depends_on`. The
  order below is the operational dependency model, not a requirement that
  Terraform serialize every independent resource.

  ### 1. Read and validate existing AWS resources

  Terraform first reads:

  - the current account and region
  - the selected VPC
  - configured or discovered private subnets
  - subnet Availability Zones
  - public subnets for the internet-facing ALB
  - an existing Route53 zone when `TF_VAR_route53_zone_id` is set

  Validation flags private subnets outside the VPC, fewer than two
  Availability Zones, an incorrect or private Route53 zone, and a custom
  domain without a certificate ARN. The private subnets must have NAT
  egress; public ALB subnets must route to an internet gateway.

  ### 2. Create IAM identities and Pod Identity policies

  Terraform creates:

  - EKS cluster and managed-node-group roles
  - Fargate execution role
  - EBS and EFS CSI IRSA roles and policies
  - ALB controller Pod Identity role and policy
  - Cluster Autoscaler Pod Identity role and policy
  - Karpenter controller and node roles
  - required policy attachments

  Karpenter uses an inline controller policy because its complete generated
  policy can exceed IAM's 6,144-character managed-policy limit. Pod Identity
  associations wait for both the cluster and their role ARNs.

  ### 3. Create ECR repositories and images

  Every private image receives an ECR repository, lifecycle policy and
  `terraform_data` build/push resource. The mirrored images include
  cert-manager, KEDA, Prometheus, NATS, Garage, Cluster Autoscaler, Karpenter,
  kgateway, sealed-secrets and the sample application. Repository names follow
  `<environment>-<resource>` (for example `eu-dev-sample-app`) and are
  referenced by Flux using the same tag.

  The repository must exist before its build can push. Image builds are
  independent of EKS readiness and run alongside other infrastructure work.
  Each provisioner uses an isolated temporary Docker configuration so parallel
  builds do not race on macOS Keychain or a shared `config.json`.

  ### 4. Create storage prerequisites

  Terraform creates the EFS filesystem, EFS security group and NFS ingress,
  then one mount target per selected Availability Zone. Selecting one subnet
  per AZ avoids EFS's uniqueness-per-AZ conflict when multiple private subnets
  exist in a zone.

  CSI add-on selection is keyed by an add-on version rather than a role ARN,
  so the IRSA role may remain unknown during a fresh plan.

  ### 5. Create the EKS control plane and shared security groups

  The cluster must be active before add-ons, managed node groups, Fargate
  profiles or Pod Identity associations can be created. The EKS module also
  creates:

  - the control plane and encryption configuration
  - control-plane logging
  - public and private endpoint access
  - cluster and node security groups
  - access configuration and cluster creator administration

  Root Terraform resources add reciprocal ingress between the EKS primary
  security group used by Fargate ENIs and the managed-node security group.
  Both directions are required for Fargate to resolve CoreDNS, reach databases
  and exchange traffic with node-hosted workloads.

  ### 6. Install pre-compute add-ons

  These add-ons deliberately use the EKS module's `before_compute` path:

  1. VPC CNI
  2. EKS Pod Identity Agent

  Installing VPC CNI after compute creates a deadlock: node groups wait for
  nodes to become `Ready`, while nodes cannot become `Ready` until VPC CNI is
  active. The Pod Identity Agent must likewise exist before credential-aware
  controllers start.

  A Terraform `moved` block preserves existing VPC CNI state when its address
  changes from the normal add-on resource to `before_compute`.

  ### 7. Create compute

  After the pre-compute add-ons are active, Terraform creates:

  - `platform` managed node group
  - `services` managed node group
  - `gateway-system` Fargate profile
  - `apps-demo` Fargate profile

  The `apps-demo` profile selects only `app=fastapi-app` pods. CloudNativePG
  PostgreSQL instances do not match, so they remain on managed nodes where
  EBS-backed PVCs can be attached.

  ### 8. Install post-compute add-ons

  After managed compute is healthy, Terraform installs:

  - CoreDNS
  - kube-proxy
  - EBS CSI driver
  - EFS CSI driver

  CoreDNS and kube-proxy must be healthy before application DNS and service
  routing. CSI controllers must be healthy before PVCs can bind.

  ### 9. Create Pod Identity and Karpenter AWS resources

  Terraform creates the ALB, Cluster Autoscaler and Karpenter Pod Identity
  associations plus:

  - Karpenter interruption queue and EventBridge rules
  - Karpenter node instance-role access entry
  - discovery tags on the private subnets
  - Karpenter discovery tag on the node security group

  Manifests contain no account-specific role ARNs; Pod Identity performs the
  AWS binding. The Karpenter security-group discovery tag is owned by the EKS
  security-group resource. A Terraform `removed` block releases the former
  standalone tag from state without deleting the live tag during upgrades.

  ### 10. Select or create the Route53 zone

  Custom DNS is optional:

  - `TF_VAR_route53_zone_id` set: read and validate the existing public zone
  - `TF_VAR_route53_zone_id` unset: create a public hosted zone

  The ALB alias is intentionally omitted in phase 1 because `alb_deployed`
  defaults to `false`; the ALB does not exist until the Kubernetes controller
  processes the kgateway Ingress.

  ### 11. Publish outputs

  After apply, Terraform exposes the cluster endpoint and name,
  `cluster_information`, `flux_vars`, ECR URLs, Karpenter values and DNS
  outputs. `bin/cluster-config.sh` is the only supported bridge from Terraform
  state into the generated Kubernetes ConfigMaps.
</details>

<details>
  <summary>Kubernetes bootstrap and workload creation order</summary>

  ### 1. Bootstrap CRDs

  Apply the CRD-only Kustomization with server-side apply and wait for every
  CRD to report `Established`:

  ```bash
  kubectl apply --server-side --force-conflicts \
    -k flux/envs/eu-west-1/crds/
  kubectl wait --for=condition=Established --timeout=300s \
    $(kubectl get crd -o name)
  ```

  This stage establishes ALB controller, Karpenter, CloudNativePG, Gloo Edge,
  KEDA and Garage CRDs. Server-side apply is required for the large vendored
  CloudNativePG and KEDA definitions.

  ### 2. Create namespaces, storage and configuration

  Create base namespaces before namespaced resources:

  ```bash
  kubectl apply -k flux/base/
  kubectl apply -k flux/modules/aws-csi/
  kubectl apply -k flux/modules/aws-logging/
  bin/cluster-config.sh apply
  ```

  `gp3` is the default StorageClass. The repository also includes the generic
  `efs-sc` StorageClass, but no EFS-backed PVC is created by this deployment.

  copies of `cluster-information` must exist in `gateway-system` and
  `autoscaling-system` before the ALB controller, Cluster Autoscaler and
  Karpenter start. `bin/cluster-config.sh apply` creates both copies. For Flux, install the
  controllers and then run `bin/cluster-config.sh apply-flux` to create the
  strict-substitution `flux-system/cluster-vars` ConfigMap.

  ### 3. Apply workloads in controller order

  | Order | Namespace | Component | Must already be ready | Readiness gate |
  | --- | --- | --- | --- | --- |
  | 1 | `cert-manager` | cert-manager | namespaces | controller, webhook and CA injector Available; webhook CA populated |
  | 2 | `observability` | Prometheus | `base`, `gp3` | Deployment Available and PVC Bound |
  | 3 | `messaging` | NATS | `base`, `gp3` | three pods Ready and stream Job Complete |
  | 4 | `object-storage` | Garage | CRD, `base`, `gp3` | three pods Ready and layout Job Complete |
  | 5 | `autoscaling-system` | KEDA | CRDs, `base` | operator, metrics API server and admission webhooks Available |
  | 6 | `autoscaling-system` | Cluster Autoscaler | `cluster-information`, Pod Identity | Deployment Available |
  | 7 | `autoscaling-system` | Karpenter controller | CRDs, `cluster-information`, Pod Identity | Deployment Available |
  | 8 | cluster-scoped | Karpenter config | Karpenter controller | `NodePool` and `EC2NodeClass` Ready |
  | 9 | `gateway-system` | ALB controller | ALB CRDs, cert-manager, Pod Identity | Deployment and webhook certificates Ready |
  | 10 | `cnpg-system` | CloudNativePG operator | CNPG CRDs and namespace | controller Deployment Available |
  | 11 | `gateway-system` | kgateway | CRDs, ALB controller, CNPG operator | gloo, discovery and proxy Available; Gloo resources Accepted |
  | 12 | `apps-demo` | sample app | CNPG operator, kgateway, `gp3` | PostgreSQL 3/3; FastAPI Deployment Available |
  | 13 | `apps-demo` | KEDA demo, optional | KEDA and sample app | `ScaledObject` Ready |

  cert-manager's leader-election RBAC belongs in `kube-system` while its
  controllers run in `cert-manager`; the environment Kustomization must not
  override the vendored namespaces. Proceed to ALB certificates only after the
  validating webhook's CA bundle is populated.

  KEDA, CloudNativePG, the ALB controller and kgateway should use server-side
  apply so large CRDs and chart-managed resources do not hit the client-side
  annotation limit.

  The NATS stream Job uses a writable `/tmp` as both `HOME` and `workingDir`.
  The non-root NATS CLI otherwise cannot read/write its schema state.

  The Gloo Edge chart already creates `gateway-proxy` and
  `gateway-proxy-ssl`; do not add another Gateway on port 8080. A duplicate
  listener is rejected and leaves Envoy without an application listener.

  The ALB health check uses `traffic-port`, which resolves to Envoy's
  registered pod port 8080. `/healthz` is a direct VirtualService response and
  must return HTTP 200 independently of the application hostname.

  CloudNativePG must be Available before the PostgreSQL `Cluster` is created.
  The FastAPI pod resolves `postgresql-rw`; its readiness is not complete
  until the database schema initializes and the Deployment remains Available.
</details>

<details>
  <summary>Flux dependency DAG</summary>

  Flux automates the ordered workload model after the manual prerequisites:

  1. install `flux/modules/flux-system/`
  2. wait for source-controller and kustomize-controller
  3. run `bin/cluster-config.sh apply-flux`
  4. apply `flux/envs/eu-west-1/flux-system/`

  Only committed files reachable from `main` are reconciled.

  ### Level 0: roots

  - `crds`
  - `base`

  ### Level 1: base consumers

  - `storage` depends on `base`
  - `logging` depends on `base`
  - `cert-manager` depends on `base`
  - `cluster-autoscaler` depends on `base`
  - `prometheus` depends on `base` and `storage`
  - `nats` depends on `base` and `storage`

  ### Level 2: CRD and storage consumers

  - `garage` depends on `base`, `crds` and `storage`
  - `keda` depends on `base` and `crds`
  - `karpenter` depends on `base` and `crds`
  - `cloudnative-pg` depends on `crds`
  - `aws-load-balancer-controller` depends on `cert-manager` and `crds`

  ### Level 3: controller-owned custom resources

  - `karpenter-config` depends on `karpenter`
  - `kgateway` depends on `crds`, `aws-load-balancer-controller` and
    `cloudnative-pg`

  ### Level 4: application

  - `sample-app` depends on `cloudnative-pg`, `kgateway` and `storage`

  ### Level 5: optional autoscaling example

  - `keda-demo` depends on `keda` and `sample-app`

  `wait: true` blocks a dependent Kustomization until its dependencies'
  applied resources are healthy. `karpenter-config` and `kgateway` use
  `wait: false` because kstatus cannot assess every Karpenter and Gloo custom
  resource kind; inspect those resource statuses explicitly after Flux applies
  them.
</details>

<details>
  <summary>ALB, target health and Terraform DNS phase</summary>

  kgateway creates the `kgateway-alb` Ingress. The ALB controller then creates
  the ALB, HTTP/HTTPS listeners, target group, `TargetGroupBinding` and
  controller-managed security-group rules.

  Wait for the Ingress address, then verify target health:

  ```bash
  kubectl -n gateway-system get ingress kgateway-alb
  kubectl -n gateway-system get targetgroupbinding

  TG_ARN="$(
    kubectl -n gateway-system get targetgroupbinding \
      -o jsonpath='{.items[0].spec.targetGroupARN}'
  )"
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN"
  ```

  Every target must be `healthy` on port 8080. A `502` from the ALB is a target
  or upstream-routing problem, not proof of a DNS problem.

  Once the ALB is healthy, run the second Terraform phase:

  ```bash
  terraform -chdir=aws/envs/eu-west-1 plan \
    -var="alb_deployed=true" \
    -out=tfplan
  terraform -chdir=aws/envs/eu-west-1 apply tfplan
  ```

  Terraform creates one alias `A` record:

  ```text
  <app_subdomain>.<domain_name> -> ALB
  ```

  The ALB data lookup matches:

  - `elbv2.k8s.aws/cluster`
  - `ingress.k8s.aws/stack=<ENV_PREFIX>-ingress`

  If `TF_VAR_route53_zone_id` selects an existing delegated zone, Terraform
  creates only the application alias and preserves all other records. Do not
  change the registrar's nameservers. If no zone ID is configured, Terraform
  creates a new zone and the registrar must use its reported nameservers:

  ```bash
  terraform -chdir=aws/envs/eu-west-1 output route53_nameservers
  ```

  For public DNS troubleshooting, query the selected Route53 zone directly
  before investigating the ALB. A correct answer from the authoritative zone
  with no public answer usually means the parent domain still delegates to
  different nameservers.
</details>

<details>
  <summary>Acceptance gates and failure boundaries</summary>

  A deployment is complete only when all gates pass:

  ```bash
  # Infrastructure has no drift
  terraform -chdir=aws/envs/eu-west-1 plan \
    -var="alb_deployed=true" \
    -detailed-exitcode

  # Kubernetes and controller health
  kubectl get nodes
  kubectl -n apps-demo get cluster postgresql
  kubectl get nodepool,ec2nodeclass.karpenter.k8s.aws

  # Required one-shot workloads
  kubectl -n messaging wait --for=condition=complete \
    job/nats-stream-setup --timeout=60s
  kubectl -n object-storage wait --for=condition=complete \
    job/garage-layout-bootstrap --timeout=60s

  # Public application path
  curl "https://$(terraform -chdir=aws/envs/eu-west-1 \
    output -raw app_hostname)/"
  ```

  Expected state:

  - no node is `NotReady`
  - no active pod is Pending, CrashLooping or unready
  - CloudNativePG reports three healthy instances
  - ALB targets are healthy on port 8080
  - HTTP redirects to HTTPS
  - the application returns a valid HTTPS response

  #### Safe recovery paths

  **Terraform fails during apply**

  Preserve state, diagnose the failed resource, fix configuration and create a
  fresh plan. Do not recreate an AWS object manually without importing an
  object that was created before Terraform recorded it.

  **`no matches for kind`**

  The CRD was not established. Re-run the server-side CRD bootstrap, wait for
  `Established`, and then reapply the affected Kustomization.

  **CRD annotation-size overflow**

  Do not retry with client-side apply. Use:

  ```bash
  kubectl apply --server-side --force-conflicts
  ```

  **cert-manager rejects an object with an unknown CA**

  Do not delete the webhook configuration as a workaround. Verify controller,
  webhook and CA-injector availability; leader-election RBAC in
  `kube-system`; Service DNS; the CA bundle; and webhook certificates.

  **Fargate cannot resolve cluster services**

  Verify CoreDNS and the reciprocal node/Fargate security-group rules. DNS
  failures from both Gloo xDS and the sample database usually share one
  network cause. Restart only long-lived workloads that cached the failure
  after the network path is corrected.

  **ALB targets are unhealthy**

  Check in order:

  1. target IP and port
  2. health-check port `traffic-port`
  3. Envoy listeners 8080 and 8443
  4. accepted Gloo `Gateway` resources
  5. accepted VirtualServices
  6. `/healthz` direct response
  7. ALB security-group ingress to the registered target port

  **Public DNS does not resolve**

  First query the Terraform-selected hosted zone. If it answers correctly,
  inspect the registrar's parent delegation. AWS application resources can be
  healthy while public DNS still points to another zone.
</details>

<details>
  <summary>Reverse dependency order for teardown</summary>

  Creation order and deletion order are related:

  1. suspend/remove Flux without pruning workloads
  2. delete the Ingress while the ALB controller is running
  3. delete Karpenter configuration while Karpenter is running
  4. delete KEDA custom resources while KEDA is running
  5. delete the CloudNativePG `Cluster` while its operator is running
  6. wait for PVCs and PVs to disappear
  7. remove operators, controllers, namespaces and CRDs
  8. destroy Terraform with `alb_deployed` left false

  One aggregate deletion is not a safe substitute for these controller-owned
  cleanup stages. It can remove the controller before it has released the ALB,
  Karpenter instance profile, KEDA finalizer or database volumes. Follow the
  detailed [Teardown](#teardown) commands below.
</details>

<details>
  <summary>Source-of-truth files</summary>

  | Concern | Source |
  | --- | --- |
  | Environment inputs | `.env.example` and local `.env` |
  | Terraform root graph | `aws/envs/eu-west-1/*.tf` |
  | EKS add-on ordering | `aws/modules/eks-cluster/main.tf` |
  | ECR image build | `aws/modules/ecr/main.tf` |
  | CRD bootstrap | `flux/envs/eu-west-1/crds/kustomization.yaml` |
  | Flux dependency DAG | `flux/envs/eu-west-1/flux-system/kustomizations.yaml` |
  | Terraform-to-Kubernetes values | `bin/cluster-config.sh` |
  | Manual Flux-equivalent rendering | `bin/render.sh` |
  | Validation gate | `bin/check.sh` |
  | Operational commands | this README |

  If this section and the implementation disagree, treat the mismatch as a
  deployment defect and update the code and this README together.
</details>

## Getting Started

### Prerequisites

<details>
  <summary>Required tools and local setup</summary>

- AWS CLI with credentials for the target account (a named profile set in
  `.env`, or the default credential chain)
- Terraform `~> 1.14.0`
- kubectl
- Docker running locally (for ECR image builds)
- Docker Buildx with a builder capable of multi-platform pushes
- kustomize (for validation)
- kubeconform (strict Kubernetes 1.37 manifest validation)
- Pluto (removed/deprecated API detection)
- Flux CLI v2.10.0 (for re-vendoring Flux manifests; optional for watching
  and forcing reconciliation)
- kind 1.37 (optional server-side dry runs)
- Python 3 (`bin/cluster-config.sh`, `bin/render.sh`)

The local gate also needs a Python environment with PyYAML:

```bash
python3 -m venv build/venv
build/venv/bin/pip install pyyaml
```

The ECR module publishes `linux/amd64` and `linux/arm64` image indexes by
default. Before the first `terraform apply`, enable the Docker Desktop
containerd image store or configure a Buildx container builder:

```bash
docker buildx create --name multiarch --driver docker-container --use
docker buildx inspect --bootstrap
```

The cluster is created on Kubernetes **1.37**. Run `bin/check.sh` before
committing infrastructure or Kubernetes changes. The gate needs no AWS
account; its add-on availability check runs only when AWS credentials are
available.
</details>

### Configuration

<details>
  <summary>Account configuration and placeholder substitution</summary>

Nothing account-specific is committed. Your AWS profile, environment tag,
VPC and (optionally) domain live in a git-ignored `.env` file:

```bash
cp .env.example .env    # then edit it
```

`bin/` scripts load `.env` automatically. For `terraform`, `aws` and
`kubectl` in your own shell, load it first:

```bash
set -a; . ./.env; set +a
```

`TF_VAR_environment` is the short deployment tag and defaults to `eu-dev`.
Platform-owned compute, IAM, storage and image names use
`<environment>-<resource>`:

| Environment tag | Physical region | Example EKS name | Example ECR repository |
| --- | --- | --- | --- |
| `eu-dev` | `eu-west-1` | `eu-dev-eks` | `eu-dev-sample-app` |
| `eu-prd` | `eu-west-1` | `eu-prd-eks` | `eu-prd-sample-app` |
| `us-dev` | a US region root such as `us-east-1` | `us-dev-eks` | `us-dev-sample-app` |
| `us-stg` | a US region root such as `us-east-1` | `us-stg-eks` | `us-stg-sample-app` |

Keep the tag stable after creation. Changing it changes names and therefore
causes Terraform to replace name-immutable resources, including the EKS
cluster, IAM roles and ECR repositories.
Tags are limited to 7 characters because the Karpenter EventBridge rule-name
prefix must remain within the provider limit.

The environment tag is not the physical region. The AWS provider attaches
`environment`, `region`, `project` and `managed-by` default tags to every
taggable resource. Resource-specific `Name` tags use the same
`<environment>-<resource>` value where a prefixable platform name exists;
domain-controlled names, such as a Route53 zone, retain their required DNS
value.

Terraform reads its inputs from the `TF_VAR_*` variables. The Kubernetes
manifests contain `${VAR}` placeholders (ECR registry, environment tag,
cluster name, optional hostname and certificate). Flux fills them in from the
`flux-system/cluster-vars` ConfigMap, which `bin/cluster-config.sh` generates
from Terraform outputs. Without Flux, `bin/render.sh` does the same locally.
`flux/envs/eu-west-1/cluster-vars.example.env` lists the variables.
</details>

#### Network

<details>
  <summary>VPC subnet and endpoint requirements</summary>

The VPC must already exist (`TF_VAR_vpc_id`). In at least two Availability
Zones it needs:

- **Private subnets** with outbound internet access through a NAT gateway.
  The control plane ENIs, managed node groups, Fargate pods, Karpenter nodes
  and EFS mount targets go here. VPC endpoints alone are not enough: some
  images come from ghcr.io, quay.io and public.ecr.aws, and Flux pulls this
  repository from GitHub.
- **Public subnets** with a route to an internet gateway, for the
  internet-facing ALB. The ALB controller picks subnets tagged
  `kubernetes.io/role/elb` or, if none are tagged, subnets with that route.

By default Terraform uses every subnet in the VPC that doesn't auto-assign
public IPs as a private subnet. If the VPC also has database or other
isolated subnets, list the private ones in `TF_VAR_private_subnet_ids`.
`terraform plan` fails if the subnets aren't in the VPC or don't span two
Availability Zones.

The Kubernetes API endpoint has both private and public access, and the
public endpoint accepts any source address.
</details>

#### Custom domain (optional)

<details>
  <summary>Regional certificate, hosted zone and HTTPS component</summary>

By default the sample app is served over plain HTTP on the ALB's own DNS name,
and no Route53 resources are created. To serve it on your own hostname over
HTTPS:

1. Create (or reuse) an ACM certificate in `eu-west-1` that covers the
   hostname, e.g. `books.example.com`.
2. Set `TF_VAR_domain_name`, `TF_VAR_acm_certificate_arn` and optionally
   `TF_VAR_app_subdomain` (default `books`) in `.env`. To reuse an existing
   public hosted zone, also set `TF_VAR_route53_zone_id`; otherwise Terraform
   creates a new hosted zone.
3. Uncomment `- custom-domain` under `components:` in
   `flux/envs/eu-west-1/kgateway/kustomization.yaml`. This adds the hostname
   rule, the HTTPS listener and the HTTP→HTTPS redirect.

The component is intentionally absent from the default kustomization, so the
HTTP-only ALB deployment remains usable without domain variables. Enabling the
component requires committed overlay configuration for Flux to reconcile it.

Terraform uses that hosted zone and creates the alias record once the ALB
exists (Step 5). `bin/cluster-config.sh` refuses to continue if the component
is enabled but no domain is set.
</details>

### Virgin Deployment (First Time)

Use the `System Design` section above for the resource graph, readiness gates,
failure boundaries and Flux DAG that back this runbook.

A fresh deployment runs Terraform, then the Kubernetes manifests. With a
custom domain there is a second Terraform phase, because the Route53 ALB alias
record depends on the ALB existing, which is created by the K8s ALB controller
after it processes the Ingress resource.

Run every command from the repository root.

<details>
  <summary>Step 1 — Terraform infrastructure and ECR images</summary>

```bash
set -a; . ./.env; set +a

terraform -chdir=aws/envs/eu-west-1 init
terraform -chdir=aws/envs/eu-west-1 plan -out=tfplan
terraform -chdir=aws/envs/eu-west-1 apply tfplan
```

This creates about 150 resources: IAM roles (the ALB controller, Cluster Autoscaler and Karpenter use EKS Pod Identity; the CSI drivers use IRSA), EKS cluster (~15-20 min), node groups, Fargate profiles, ECR repos (builds+pushes all 20 images), EFS filesystem, add-ons, and either reuses the configured Route53 zone or creates one for a custom domain. The `alb_deployed` variable defaults to `false`, so no Route53 ALB record is created yet.
</details>

<details>
  <summary>Step 2 — Configure kubectl</summary>

```bash
aws eks update-kubeconfig --region eu-west-1 \
  --name "$(terraform -chdir=aws/envs/eu-west-1 output -raw cluster_name)"
kubectl get nodes   # verify nodes are Ready
```
</details>

<details>
  <summary>Step 3 — Kubernetes prerequisites</summary>

`flux/modules/flux-system/` vendors a real FluxCD control plane
(source-controller + kustomize-controller) that continuously reconciles
this repo from git and prunes drift -- not just plain Kustomize applied by
hand. Steps 0-4 below are unavoidable manual prerequisites either way:
Flux has no access to Terraform state, so the CRD bootstrap and the
`cluster-information` ConfigMap generation can't be delegated to it. After
step 4, pick **Option A** (Flux, recommended) or **Option B** (manual, no
Flux) for everything else.

```bash
# 0. CRD bootstrap — must be Established before their CRs validate.
# A single `kubectl apply -k flux/envs/eu-west-1/` on a virgin cluster will
# otherwise fail with "no matches for kind" for NodePool/EC2NodeClass,
# CloudNativePG's Cluster, Gloo Edge's Settings/VirtualService/Gateway, and
# KEDA's ScaledObject. Server-side apply avoids the annotation size limit on
# the large CloudNativePG and KEDA CRDs.
kubectl apply --server-side --force-conflicts -k flux/envs/eu-west-1/crds/

# 1. Base namespaces
kubectl apply -k flux/base/

# 2. StorageClasses (gp3 default + EFS)
kubectl apply -k flux/modules/aws-csi/

# 3. Fargate logging
kubectl apply -k flux/modules/aws-logging/

# 4. cluster-information ConfigMaps — generated from Terraform outputs, not
# applied from the checked-in file (which holds placeholder values). Copies
# are required in gateway-system and autoscaling-system. A missing copy leaves
# one of these controllers in
# CreateContainerConfigError.
bin/cluster-config.sh apply
```
</details>

<details>
  <summary>Option A — Install Flux and hand off reconciliation (recommended)</summary>

```bash
# One-time: install the Flux controllers themselves.
kubectl apply -k flux/modules/flux-system/
kubectl -n flux-system rollout status deployment/source-controller
kubectl -n flux-system rollout status deployment/kustomize-controller

# One-time: the variables Flux substitutes into the manifests' ${VAR}
# placeholders (flux-system/cluster-vars, generated from Terraform outputs).
# kustomize-controller runs with strict substitution, so a missing variable
# fails the reconciliation instead of applying an empty value.
bin/cluster-config.sh apply-flux

# One-time: point Flux at this repo (flux/envs/eu-west-1/flux-system/source.yaml
# is a public-HTTPS GitRepository tracking `main` -- no deploy key needed, but
# also no reconciliation of anything not yet committed and pushed there).
kubectl apply -k flux/envs/eu-west-1/flux-system/

# Watch progress -- replaces the manual `rollout status` polling in Option B.
flux get kustomizations -A --watch
# or, without the Flux CLI:
kubectl -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io -w
```

Flux then applies cert-manager, Prometheus, NATS, Garage, KEDA (and the
`keda-demo` ScaledObject), Cluster Autoscaler, Karpenter, the ALB controller,
CloudNativePG, kgateway, and the sample app itself, in the dependency order
encoded in `flux/envs/eu-west-1/flux-system/kustomizations.yaml`
(`dependsOn` + `wait: true`), then keeps reconciling and pruning drift on
its own. Skip to Step 4 once `flux get kustomizations -A` shows everything
`Ready`. From then on, deploying a change is `git push` to `main` -- see
"Normal Deployments" below.
</details>

<details>
  <summary>Option B — Continue manually without Flux</summary>

These manifests contain `${VAR}` placeholders, so they go through
`bin/render.sh`, which builds the kustomization and fills the placeholders in
from the Terraform outputs, the way Flux would. Plain `kubectl apply -k` would
apply them unfilled.

```bash
# 5. cert-manager (wait for pods Ready — ALB controller depends on its webhooks)
bin/render.sh flux/envs/eu-west-1/cert-manager | kubectl apply -f -
kubectl -n cert-manager rollout status deployment/cert-manager
kubectl -n cert-manager rollout status deployment/cert-manager-webhook
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector

# 6. Prometheus (scrapes prometheus.io/scrape-annotated pods, e.g. cluster-autoscaler)
bin/render.sh flux/modules/prometheus | kubectl apply -f -
kubectl -n observability rollout status deployment/prometheus

# 7. NATS (3-node JetStream cluster) — deployed and healthy, but not wired
# into the sample app's code; see Known Limitations.
bin/render.sh flux/modules/nats | kubectl apply -f -
kubectl -n messaging rollout status statefulset/nats

# 8. Garage (S3-compatible object storage) — a genuine, healthy 3-node
# cluster with a demo bucket/key, reachable only in-cluster; not wired into
# the sample app's code. The layout-bootstrap Job assigns the cluster layout
# and creates the demo bucket/key after the pods are Ready. See Known
# Limitations.
bin/render.sh flux/modules/garage | kubectl apply -f -
kubectl -n object-storage rollout status statefulset/garage
kubectl -n object-storage wait --for=condition=complete job/garage-layout-bootstrap --timeout=600s

# 9. KEDA (event-driven autoscaling operator). The `keda-demo` ScaledObject
# that uses it is intentionally NOT applied here — see step 15's note.
bin/render.sh flux/modules/keda | kubectl apply --server-side --force-conflicts -f -
kubectl -n autoscaling-system rollout status deployment/keda-operator

# 10. Cluster Autoscaler — scales the Terraform-managed node groups; this is
# the autoscaler that actually serves normal workloads (sample-app, CNPG).
bin/render.sh flux/modules/cluster-autoscaler | kubectl apply -f -
kubectl -n autoscaling-system rollout status deployment/cluster-autoscaler

# 11. Karpenter — demo/teaching only in this repo. Its NodePool taints nodes
# karpenter.sh/provisioned:NoSchedule and only the "inflate" example pod
# (flux/modules/karpenter-config/inflate.yaml, replicas: 0) tolerates it and
# opts in via nodeSelector. Scale it up to see Karpenter provision a node;
# it does not participate in scaling the sample app.
bin/render.sh flux/modules/karpenter | kubectl apply -f -
kubectl -n autoscaling-system rollout status deployment/karpenter
bin/render.sh flux/modules/karpenter-config | kubectl apply -f -

# 12. ALB controller (depends on cert-manager for webhook TLS, and on the
# cluster-information ConfigMap above for CLUSTER_NAME)
bin/render.sh flux/modules/aws-load-balancer-controller |
  kubectl apply --server-side --force-conflicts -f -
kubectl -n gateway-system rollout status deployment/aws-load-balancer-controller

# 13. CloudNativePG operator (wait for controller Ready — manages PostgreSQL Cluster CRs)
bin/render.sh flux/modules/cloudnative-pg | kubectl apply --server-side --force-conflicts -f -
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager

# 14. kgateway (API gateway + Ingress → creates ALB)
bin/render.sh flux/envs/eu-west-1/kgateway | kubectl apply --server-side --force-conflicts -f -
kubectl -n gateway-system rollout status deployment/gloo
kubectl -n gateway-system rollout status deployment/gateway-proxy

# 15. Sample app (FastAPI + CloudNativePG PostgreSQL cluster). Its Deployment
# has no `replicas:` field -- once KEDA is installed (step 9) you may apply
# flux/modules/keda-demo/ by hand to let its ScaledObject/HPA own the count;
# it's excluded from this list and from the flux/envs/eu-west-1/ aggregate
# because ScaledObject is a KEDA CRD kind with no ordering guarantee in a
# single-shot `kubectl apply -k` (see flux/modules/keda-demo/kustomization.yaml).
bin/render.sh flux/modules/sample-app | kubectl apply -f -
kubectl -n apps-demo rollout status deployment/fastapi-deployment
# Wait for PostgreSQL cluster to be ready (3 instances)
kubectl -n apps-demo wait --for=condition=Ready cluster/postgresql --timeout=300s
```
</details>

<details>
  <summary>Step 4 — Verify that the ALB is created</summary>

Wait for the ALB controller to provision the load balancer from the Ingress resource:

```bash
kubectl -n gateway-system get ingress kgateway-alb
# Wait until ADDRESS column shows an ALB DNS name
```

Without a custom domain, skip to Step 7.
</details>

<details>
  <summary>Step 5 — Create the Route53 ALB record (custom domain only)</summary>

Once the ALB exists, create the Route53 alias record:

```bash
set -a; . ./.env; set +a

terraform -chdir=aws/envs/eu-west-1 plan -var="alb_deployed=true" -out=tfplan
terraform -chdir=aws/envs/eu-west-1 apply tfplan
```

This creates the `<app_subdomain>.<domain_name>` → ALB alias record
(`terraform -chdir=aws/envs/eu-west-1 output app_hostname`).
</details>

<details>
  <summary>Step 6 — Configure public DNS (custom domain only)</summary>

If `TF_VAR_route53_zone_id` is unset, Terraform created a new hosted zone. If
the domain is registered with an external registrar, update the NS records at
the registrar to point to its Route53 nameservers:

```bash
terraform -chdir=aws/envs/eu-west-1 output route53_nameservers
```

Copy the 4 nameserver values to the domain registrar's NS records.
When `TF_VAR_route53_zone_id` points to the existing delegated zone, this
step is unnecessary.
</details>

<details>
  <summary>Step 7 — Verify end-to-end traffic</summary>

```bash
# Without a custom domain: plain HTTP on the ALB's DNS name
curl "http://$(kubectl -n gateway-system get ingress kgateway-alb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')/"

# With a custom domain
curl "https://$(terraform -chdir=aws/envs/eu-west-1 output -raw app_hostname)/"
# Either should return the FastAPI sample app response
```

Traffic flow:
- Default: ALB DNS name → ALB (HTTP) → gateway-proxy → VirtualService → FastAPI
- Custom domain: app hostname → Route53 → ALB (HTTPS, TLS 1.3) → gateway-proxy (HTTP) → VirtualService → FastAPI
</details>

### Normal Deployments (Subsequent Changes)

For changes after the initial setup:

<details>
  <summary>Terraform changes</summary>

```bash
set -a; . ./.env; set +a

terraform -chdir=aws/envs/eu-west-1 plan -var="alb_deployed=true" -out=tfplan
# Review the plan
terraform -chdir=aws/envs/eu-west-1 apply tfplan
```

Note: with a custom domain, always pass `-var="alb_deployed=true"` after the ALB exists, otherwise Terraform will try to destroy the Route53 ALB record. Without one the flag has no effect.

If a change affects the values in `cluster_information` or `flux_vars` (for
example a new domain), re-run `bin/cluster-config.sh apply` and, with Flux,
`bin/cluster-config.sh apply-flux`.
</details>

<details>
  <summary>Kubernetes changes with Flux or manual apply</summary>

If you installed Flux (Option A above): commit and push to `main`. Flux
picks up the change on its next `GitRepository` poll (`interval: 1m`) and
reconciles it automatically -- no manual `kubectl apply` needed.

```bash
# Force an immediate sync instead of waiting for the poll interval
flux reconcile source git aws-sample-eks-platform -n flux-system
flux reconcile kustomization <changed-module> -n flux-system

# Check status
flux get kustomizations -A
```

If you're on the manual path (Option B): validate, then apply by hand.

```bash
# Validate first
bin/check.sh

# Apply the specific module that changed
bin/render.sh flux/modules/<changed-module> | kubectl apply --server-side --force-conflicts -f -
# or apply the full environment (does not include flux-system, keda-demo)
bin/render.sh flux/envs/eu-west-1 | kubectl apply --server-side --force-conflicts -f -
```
</details>

<details>
  <summary>Application image updates</summary>

When updating application code or Dockerfiles:

1. Update the `image_tag` in `aws/envs/eu-west-1/ecr.tf`
2. Run `terraform apply` — the ECR module detects source hash changes and rebuilds/pushes
3. Update the image tag in the corresponding Flux deployment manifest
4. Apply the Kubernetes change: push to `main` (Flux), or `bin/render.sh flux/modules/<app> | kubectl apply -f -`
</details>

### Teardown

Run from the repository root while the Terraform state still exists
(`bin/render.sh` reads its outputs). The order matters. The ALB controller,
Karpenter and KEDA must still be running when the objects they clean up are
deleted, and the EBS CSI driver must delete the volumes before Terraform
removes it. Otherwise the ALB, Karpenter's EC2 instances, its instance
profile or EBS volumes are left behind. A leftover instance profile also makes
the destroy fail, because it keeps the Karpenter node role in use.

<details>
  <summary>Controller-safe teardown procedure</summary>

```bash
set -a; . ./.env; set +a

# 0. With Flux only: suspend every Kustomization, then remove Flux. Deleting
# a suspended Kustomization prunes nothing, so the workloads stay for the
# ordered steps below instead of all being deleted at once.
kubectl -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io -o name \
  | xargs -n1 kubectl -n flux-system patch --type merge -p '{"spec":{"suspend":true}}'
kubectl delete -k flux/envs/eu-west-1/flux-system/
kubectl delete -k flux/modules/flux-system/

# 1. The Ingress. The ALB controller deletes the ALB, its target groups and
# security groups, then releases the Ingress.
kubectl -n gateway-system delete ingress kgateway-alb --ignore-not-found --timeout=10m

# 2. Karpenter's NodePool and EC2NodeClass. Karpenter terminates the nodes it
# launched and deletes the instance profile it created for them.
bin/render.sh flux/modules/karpenter-config | kubectl delete -f - --ignore-not-found --timeout=10m

# 3. The keda-demo ScaledObject, if it was applied (KEDA holds a finalizer).
bin/render.sh flux/modules/keda-demo | kubectl delete -f - --ignore-not-found --timeout=5m

# 4. Delete the sample app and its CloudNativePG Cluster while the CNPG
# operator is still running, then wait for the database PVCs to disappear.
bin/render.sh flux/modules/sample-app | kubectl delete -f - --ignore-not-found --timeout=15m
kubectl -n apps-demo wait --for=delete cluster/postgresql --timeout=10m
while [ -n "$(kubectl -n apps-demo get pvc -o name)" ]; do sleep 10; done

# 5. Everything else. The database CR and its claims are already gone, so it
# is now safe to remove the CNPG operator, namespace and CRDs.
bin/render.sh flux/envs/eu-west-1 | kubectl delete -f - --ignore-not-found --timeout=15m

# 6. Wait until the EBS CSI driver has deleted every volume.
while [ -n "$(kubectl get pv -o name)" ]; do sleep 10; done

# 7. Destroy. Leave alb_deployed at its default (false): the ALB is gone and
# looking it up would fail. The Route53 record is destroyed either way.
terraform -chdir=aws/envs/eu-west-1 plan -destroy -out=destroy.tfplan
terraform -chdir=aws/envs/eu-west-1 apply destroy.tfplan
```
</details>

<details>
  <summary>Teardown notes and externally managed resources</summary>

- **Custom domain:** when Terraform created the hosted zone
  (`TF_VAR_route53_zone_id` unset), point the registrar back at the previous
  nameservers before step 7 and delete any extra records. Terraform deletes
  the zone only if it holds nothing besides NS/SOA and the app alias. With
  `TF_VAR_route53_zone_id` set, Terraform deletes only the app alias and leaves
  the existing zone and its other records untouched.
- **ECR:** repositories are deleted with their images (`force_delete` in
  `aws/envs/eu-west-1/ecr.tf`). The next `terraform apply` rebuilds them.
- **Fargate logs:** Fluent Bit creates the CloudWatch log group
  `/aws/eks/fargate/logs`, which Terraform doesn't manage. Delete it if no
  other cluster in the account writes to it:
  `aws logs delete-log-group --log-group-name /aws/eks/fargate/logs --region eu-west-1`.
- EKS cluster deletion takes about 10–15 minutes.
</details>

## Known Limitations

<details>
  <summary>Storage examples</summary>

Storage examples are incomplete (the EBS/EFS CSI drivers, IRSA roles, the EFS
filesystem, and the `gp3` StorageClass are all in place; what's missing are
usage examples):

- No standalone `PersistentVolumeClaim` / `volumeClaimTemplates` example using
  the `gp3` StorageClass outside of the NATS StatefulSet and CloudNativePG's
  `Cluster` CR, which provision their own PVCs internally.
- `flux/modules/aws-csi/efs-sc.yaml` has no `parameters` block
  (`fileSystemId`, `provisioningMode`, `directoryPerms`) — the Terraform
  `efs_file_system_id` output is not yet wired into the StorageClass, and there
  is no EFS-backed PV/PVC example.
</details>

<details>
  <summary>Demo versus production caveats</summary>

These caveats apply in the same spirit as the Karpenter note in Step 3
(Option B, step 11):

- **KEDA**: real, not inert. `flux/modules/keda-demo/scaledobject.yaml`'s
  cron trigger scales the actual `fastapi-deployment` (sample-app) between
  1 and 3 replicas on a schedule; the Deployment's replica count is owned
  by the generated HorizontalPodAutoscaler, not a static `replicas:` field.
- **NATS**: a genuine, healthy 3-node JetStream cluster, but it is not
  wired into the sample app's code -- no service in this repo publishes or
  subscribes to it. It's available for use, the same honesty pattern as
  Prometheus before anything scrapes custom application metrics.
- **Garage**: a genuine, healthy 3-node S3-compatible object store with a
  demo bucket (`demo-bucket`) and access key created by the
  `garage-layout-bootstrap` Job. The S3 API is reachable only in-cluster
  (`garage-s3.object-storage.svc.cluster.local:3900`) and is not wired into the
  sample app's code -- same honesty pattern as NATS. Additional caveats:
  the LMDB metadata engine can corrupt after an unclean shutdown
  (mitigated, but not eliminated, by `metadata_auto_snapshot_interval = "6h"`
  in `garage.toml`); Prometheus scrapes `:3903/metrics` unauthenticated
  because `metrics_token` is deliberately left empty (annotation-based
  scraping can't attach a bearer token) -- demo-only; and the per-pod zones
  (`zone-0`/`zone-1`/`zone-2`) are logical placeholders, not real AWS AZs.
- **Flux**: `flux/modules/flux-system/` and
  `flux/envs/eu-west-1/flux-system/` are real, not a naming convention over
  plain `kubectl apply -k` -- but reconciliation only starts once these
  manifests are committed and pushed to `main` (see Step 3, Option A).
</details>

---

Fawad Mazhar <fawadmazhar@hotmail.com> 2026

---
