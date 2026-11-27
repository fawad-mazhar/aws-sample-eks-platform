# Dependency Sequence

Flux reconciles resources committed and pushed to `main`; local or unpushed
changes are not source-of-truth changes.

```text
Terraform infrastructure + Ready Kubernetes nodes
        |
        v
Server-side CRD bootstrap
        |
        v
Base namespaces
        |
        v
Storage, logging and cluster ConfigMaps
        |
        v
Flux controllers
  - source-controller
  - kustomize-controller
        |
        v
GitRepository(main)
        |
        v
Flux Kustomization DAG
        |
        +-----------+------------+-------------+----------------+
        v           v            v             v                v
   Prometheus     NATS        Garage         KEDA          Cluster
                                                   Autoscaler

Garage is independent storage data-plane work; it does not create the
sample application or a dependency edge to sample-app.

crds -> Karpenter -> karpenter-config

base -> cert-manager
crds + cert-manager -> ALB controller
crds -> CloudNativePG
crds + ALB controller + CloudNativePG -> kgateway
storage + CloudNativePG + kgateway -> sample-app
sample-app + KEDA -> keda-demo
```

## Bootstrap

1. Apply Terraform, configure `kubectl`, and wait for cluster nodes to become
   `Ready`.
2. Establish external CRDs with server-side apply before creating custom
   resources.
3. Apply base namespaces, AWS StorageClasses and Fargate logging.
4. Create the Terraform-derived ConfigMaps:
   - `cluster-information` in `gateway-system` and `autoscaling-system`
   - `cluster-vars` in `flux-system`
5. Install the Flux controllers, then apply the `GitRepository` and Flux
   `Kustomization` DAG.

The `cluster-vars` ConfigMap supplies ECR registry, environment prefix, cluster
name, Karpenter node role, hostname and certificate values to Flux substitutions.

## Flux DAG

The DAG in `flux-system/kustomizations.yaml` starts reconciliation only after
dependencies report Ready:

- `crds` and `base` are the first independent roots.
- `storage` waits for `base`; `logging` and `cert-manager` wait for `base`.
- Prometheus and NATS wait for `base` and `storage`.
- Garage waits for `base`, `crds` and `storage`.
- KEDA waits for `base` and `crds`.
- Cluster Autoscaler waits for `base`.
- Karpenter waits for `base` and `crds`; Karpenter configuration follows it.
- The ALB Controller waits for `cert-manager` and `crds`.
- CloudNativePG waits for `crds`.
- kgateway waits for `crds`, the ALB Controller and CloudNativePG.
- The sample app waits for CloudNativePG, kgateway and storage.
- KEDA demo follows both KEDA and the sample app.

`wait: true` makes readiness block dependents. `karpenter-config` and
`kgateway` use `wait: false` because kstatus cannot assess their custom
resource kinds reliably.

## Final network step

kgateway creates the Ingress and ALB. Once the ALB is healthy, a custom-domain
deployment requires a second Terraform phase with
`-var="alb_deployed=true"` to create the Route53 alias.
