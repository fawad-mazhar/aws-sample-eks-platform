# AWS Sample EKS Platform

## Directory Structure
```
aws-sample-eks-platform/
├── aws/            # Terraform: EKS cluster, IAM, ECR, networking
├── flux/           # Kubernetes manifests (Kustomize)
├── applications/   # Dockerfiles for images published to ECR
├── bin/            # Helper scripts (build, validate, plan)
└── README.md
```

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

**Step 3 — Deploy Kubernetes resources**

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
# KEDA's ScaledObject.
kubectl apply -k flux/envs/eu-west-1/crds/

# 1. Base namespaces
kubectl apply -k flux/base/

# 2. StorageClasses (gp3 default + EFS)
kubectl apply -k flux/modules/aws-csi/

# 3. Fargate logging
kubectl apply -k flux/modules/aws-logging/

# 4. cluster-information ConfigMap — generated from Terraform outputs, not
# applied from the checked-in file (whose cluster-endpoint is a placeholder).
# Must exist before Cluster Autoscaler, Karpenter, and the ALB controller,
# which all read it via non-optional configMapKeyRef and will otherwise sit
# in CreateContainerConfigError.
cd aws/envs/eu-west-1
kubectl create configmap cluster-information -n kube-system \
  --from-literal=cluster-name="$(terraform output -raw cluster_name)" \
  --from-literal=aws-region=eu-west-1 \
  --from-literal=aws-vpc-id="$(terraform output -raw vpc_id)" \
  --from-literal=cluster-endpoint="$(terraform output -raw cluster_endpoint)" \
  --from-literal=karpenter-queue="$(terraform output -raw karpenter_queue_name)" \
  --dry-run=client -o yaml | kubectl apply -f -
cd -
```

**Option A — Install Flux and hand off reconciliation (recommended)**

```bash
# One-time: install the Flux controllers themselves.
kubectl apply -k flux/modules/flux-system/
kubectl -n flux-system rollout status deployment/source-controller
kubectl -n flux-system rollout status deployment/kustomize-controller

# One-time: point Flux at this repo (flux/envs/eu-west-1/flux-system/source.yaml
# is a public-HTTPS GitRepository tracking `main` -- no deploy key needed, but
# also no reconciliation of anything not yet committed and pushed there).
kubectl apply -k flux/envs/eu-west-1/flux-system/

# Watch progress -- replaces the manual `rollout status` polling in Option B.
flux get kustomizations -A --watch
```

Flux then applies cert-manager, Prometheus, NATS, Garage, KEDA (and the
`keda-demo` ScaledObject), Cluster Autoscaler, Karpenter, the ALB controller,
CloudNativePG, kgateway, and the sample app itself, in the dependency order
encoded in `flux/envs/eu-west-1/flux-system/kustomizations.yaml`
(`dependsOn` + `wait: true`), then keeps reconciling and pruning drift on
its own. Skip to Step 4 once `flux get kustomizations -A` shows everything
`Ready`. From then on, deploying a change is `git push` to `main` -- see
"Normal Deployments" below.

**Option B — Continue manually, no Flux**

```bash
# 5. cert-manager (wait for pods Ready — ALB controller depends on its webhooks)
kubectl apply -k flux/envs/eu-west-1/cert-manager/
kubectl -n cert-manager rollout status deployment/cert-manager
kubectl -n cert-manager rollout status deployment/cert-manager-webhook
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector

# 6. Prometheus (scrapes prometheus.io/scrape-annotated pods, e.g. cluster-autoscaler)
kubectl apply -k flux/modules/prometheus/
kubectl -n kube-system rollout status deployment/prometheus

# 7. NATS (3-node JetStream cluster) — deployed and healthy, but not wired
# into the sample app's code; see Known Limitations.
kubectl apply -k flux/modules/nats/
kubectl -n nats rollout status statefulset/nats

# 8. Garage (S3-compatible object storage) — a genuine, healthy 3-node
# cluster with a demo bucket/key, reachable only in-cluster; not wired into
# the sample app's code. The layout-bootstrap Job assigns the cluster layout
# and creates the demo bucket/key after the pods are Ready. See Known
# Limitations.
kubectl apply -k flux/modules/garage/
kubectl -n garage rollout status statefulset/garage
kubectl -n garage wait --for=condition=complete job/garage-layout-bootstrap --timeout=600s

# 9. KEDA (event-driven autoscaling operator). The `keda-demo` ScaledObject
# that uses it is intentionally NOT applied here — see step 15's note.
kubectl apply -k flux/modules/keda/
kubectl -n kube-system rollout status deployment/keda-operator

# 10. Cluster Autoscaler — scales the Terraform-managed node groups; this is
# the autoscaler that actually serves normal workloads (sample-app, CNPG).
kubectl apply -k flux/modules/cluster-autoscaler/
kubectl -n kube-system rollout status deployment/cluster-autoscaler

# 11. Karpenter — demo/teaching only in this repo. Its NodePool taints nodes
# karpenter.sh/provisioned:NoSchedule and only the "inflate" example pod
# (flux/modules/karpenter-config/inflate.yaml, replicas: 0) tolerates it and
# opts in via nodeSelector. Scale it up to see Karpenter provision a node;
# it does not participate in scaling the sample app.
kubectl apply -k flux/modules/karpenter/
kubectl -n kube-system rollout status deployment/karpenter
kubectl apply -k flux/modules/karpenter-config/

# 12. ALB controller (depends on cert-manager for webhook TLS, and on the
# cluster-information ConfigMap above for CLUSTER_NAME)
kubectl apply -k flux/modules/aws-load-balancer-controller/
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller

# 13. CloudNativePG operator (wait for controller Ready — manages PostgreSQL Cluster CRs)
kubectl apply -k flux/modules/cloudnative-pg/
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager

# 14. kgateway (API gateway + Ingress → creates ALB)
kubectl apply -k flux/envs/eu-west-1/kgateway/
kubectl -n kgateway rollout status deployment/gloo
kubectl -n kgateway rollout status deployment/gateway-proxy

# 15. Sample app (FastAPI + CloudNativePG PostgreSQL cluster). Its Deployment
# has no `replicas:` field -- once KEDA is installed (step 9) you may apply
# flux/modules/keda-demo/ by hand to let its ScaledObject/HPA own the count;
# it's excluded from this list and from the flux/envs/eu-west-1/ aggregate
# because ScaledObject is a KEDA CRD kind with no ordering guarantee in a
# single-shot `kubectl apply -k` (see flux/modules/keda-demo/kustomization.yaml).
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
kustomize build flux/envs/eu-west-1 > /dev/null

# Apply the specific module that changed
kubectl apply -k flux/modules/<changed-module>/
# or apply the full environment (does not include flux-system, keda-demo)
kubectl apply -k flux/envs/eu-west-1/
```

**Application image updates**

When updating application code or Dockerfiles:

1. Update the `image_tag` in `aws/envs/eu-west-1/ecr.tf`
2. Run `terraform apply` — the ECR module detects source hash changes and rebuilds/pushes
3. Update the image tag in the corresponding Flux deployment manifest
4. Apply the Kubernetes change: `kubectl apply -k flux/modules/<app>/`

### Teardown

Reverse order of deployment. If you installed Flux, suspend/remove it
first so kustomize-controller doesn't fight the teardown by re-applying
what you're deleting:

```bash
# 0. If Flux is installed: remove it first (this also prunes everything
# it manages, since each Kustomization has prune: true).
kubectl delete -k flux/envs/eu-west-1/flux-system/
kubectl delete -k flux/modules/flux-system/

# 1. Remove any remaining Kubernetes resources (Option B / leftovers)
kubectl delete -k flux/envs/eu-west-1/
kubectl delete -k flux/modules/keda-demo/ --ignore-not-found

# 2. Destroy Terraform resources
cd aws/envs/eu-west-1
terraform destroy -var="alb_deployed=true"
```

Note: EKS cluster deletion takes ~10-15 minutes. ECR repos with images require `force_delete = true` (already configured in the ECR module).

## Known Limitations

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

Demo-vs-real caveats for the newer additions, in the same spirit as the
Karpenter note in Step 3 (Option B, step 11):

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
  (`garage-s3.garage.svc.cluster.local:3900`) and is not wired into the
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

---

Fawad Mazhar <fawadmazhar@hotmail.com> 2026

---
