## Tasks

- Setting up aws eks
- iam cluster role
- iam node group role
- Ensure aws eks cluster is accessible through kubectl cli
- Create managed node groups
- Create iam role for Fargate profile
- add fargate profile to eks
- add aws-logging ConfigMap
- Expose application using ServiceType LoadBalancer
- EBS Volume
  - IAM configuration to use EBS as storage
  - Install and configure CSI Driver
  - Persistent storage with PVC EBS CSI Driver
  - Persistent Storage with ClaimTemplates
  - Configurations to use EFS PersistentVolumes
- Ingress Controller and ALB Setup
  - IAM Policy
  - Deploying ALB Ingress Controller Resources
  - Deploying ALB Ingress Controller to Route External Traffic
- Scaling Node Groups
  - Cluster Autoscaler for NodeGroups OR Karpenter OR both
  - IAM Policy and Role for Cluster AutoScaler
  - Observability for Cluster Autoscaler
- ECR Integration
  - Create and manage ECR repo
  - EKS to to pull ECR repos


## Conventions and Ways of Working
- Plan should be created and made part of the project illustrating backlog of tasks and their status
- Using flux for configuring all kubernetes resources 
- Using terraform for configuring all aws resources
- Should be able to deploy/undeploy resources 
- Always suggest commit message when enough work is done
- User will commit the code and give a call to proceed
- Plan should be updated accordingly
- User will add more tasks under Tasks section and agent should update the plan accordingly



## Reference projects
Code conventions from the reference projects should be preferred.
### Flux
- /Users/fawadmazhar/ss/flux-devs/flux-dev-v2
- /Users/fawadmazhar/ss/flux-admins/flux-admin-v2

### Terraform
- /Users/fawadmazhar/ss/devops/github-operations
- /Users/fawadmazhar/ss/devops/aws-landingzone

### Docker and Kubernetes 
- /Users/fawadmazhar/ss/devops/base-images 
- /Users/fawadmazhar/github/codes/k8s-references

### AWS Profile
- Use details of `nlaclassic` from ~/.aws/config
- Use eu-west-1 as region
- Use existing vpc and subnets
- Create new security groups as needed
 
### Dir Structure
**Note** Agent can also make necessary changes
`flux/` can/should contain kubernetes resources
`aws/` can/should contain terraform aws resources
`applications/` can/should docker containers later to be published to ECR. It can also be checked if terraform can build and deploy docker containers. In that case `applications` can reside inside `aws`.  

