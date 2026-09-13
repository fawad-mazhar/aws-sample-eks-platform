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

**Step 3 — Deploy Kubernetes resources (ordered)**

Resources must be applied in order due to dependencies (CRDs before the custom resources that use them, cert-manager before the ALB controller).

```bash
# 0. CRD bootstrap — must be Established before their CRs validate.
# A single `kubectl apply -k flux/envs/eu-west-1/` on a virgin cluster will
# otherwise fail with "no matches for kind" for NodePool/EC2NodeClass,
# CloudNativePG's Cluster, and Gloo Edge's Settings/VirtualService/Gateway.
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

# 5. cert-manager (wait for pods Ready — ALB controller depends on its webhooks)
kubectl apply -k flux/envs/eu-west-1/cert-manager/
kubectl -n cert-manager rollout status deployment/cert-manager
kubectl -n cert-manager rollout status deployment/cert-manager-webhook
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector

# 6. Prometheus (scrapes prometheus.io/scrape-annotated pods, e.g. cluster-autoscaler)
kubectl apply -k flux/modules/prometheus/
kubectl -n kube-system rollout status deployment/prometheus

# 7. Cluster Autoscaler — scales the Terraform-managed node groups; this is
# the autoscaler that actually serves normal workloads (sample-app, CNPG).
kubectl apply -k flux/modules/cluster-autoscaler/
kubectl -n kube-system rollout status deployment/cluster-autoscaler

# 8. Karpenter — demo/teaching only in this repo. Its NodePool taints nodes
# karpenter.sh/provisioned:NoSchedule and only the "inflate" example pod
# (flux/modules/karpenter-config/inflate.yaml, replicas: 0) tolerates it and
# opts in via nodeSelector. Scale it up to see Karpenter provision a node;
# it does not participate in scaling the sample app.
kubectl apply -k flux/modules/karpenter/
kubectl -n kube-system rollout status deployment/karpenter
kubectl apply -k flux/modules/karpenter-config/

# 9. ALB controller (depends on cert-manager for webhook TLS, and on the
# cluster-information ConfigMap above for CLUSTER_NAME)
kubectl apply -k flux/modules/aws-load-balancer-controller/
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller

# 10. CloudNativePG operator (wait for controller Ready — manages PostgreSQL Cluster CRs)
kubectl apply -k flux/modules/cloudnative-pg/
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager

# 11. kgateway (API gateway + Ingress → creates ALB)
kubectl apply -k flux/envs/eu-west-1/kgateway/
kubectl -n kgateway rollout status deployment/gloo
kubectl -n kgateway rollout status deployment/gateway-proxy

# 12. Sample app (FastAPI + CloudNativePG PostgreSQL cluster)
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

## Known Limitations

Storage examples are incomplete (the EBS/EFS CSI drivers, IRSA roles, the EFS
filesystem, and the `gp3` StorageClass are all in place; what's missing are
usage examples):

- No standalone `PersistentVolumeClaim` / `volumeClaimTemplates` example using
  the `gp3` StorageClass. CloudNativePG's `Cluster` CR is currently the only
  EBS consumer, and it provisions its own PVCs internally.
- `flux/modules/aws-csi/efs-sc.yaml` has no `parameters` block
  (`fileSystemId`, `provisioningMode`, `directoryPerms`) — the Terraform
  `efs_file_system_id` output is not yet wired into the StorageClass, and there
  is no EFS-backed PV/PVC example.

---

Fawad Mazhar <fawadmazhar@hotmail.com> 2026

---
