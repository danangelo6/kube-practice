# Sample App on AWS EKS: Terraform + Docker + GitHub Actions

A small Node.js task API (Prometheus metrics built in), containerized with Docker, scanned with **Trivy**,
pushed to **Amazon ECR**, and deployed to **Amazon EKS** by **GitHub Actions**. All AWS infrastructure is created with **Terraform**.
Monitoring: **Prometheus + Grafana**.

```
                        ┌────────────── Terraform ──────────────┐
                        │ VPC (2 AZ, public subnets, no NAT)     │
 git push ─► GitHub     │ EKS cluster + managed node group (2x)  │
   Actions              │ ECR repository                         │
 test ► Trivy ► build   │ GitHub OIDC provider + deploy IAM role │
 ► Trivy ► push ECR     └────────────────────────────────────────┘
   │
   └► OIDC ► kubectl apply ► EKS: namespace sample-app (2 pods + PDB + NLB Service)
                                   namespace monitoring (Prometheus + Grafana)
```

## Cost warning (read first)
EKS is **not free tier**. Approximate us-east-1 prices (check your region and the AWS pricing pages):

| Item | About |
|---|---|
| EKS control plane | $0.10/hour (~$73/month) |
| 2x t3.medium nodes | ~$0.083/hour total (~$61/month) |
| Network Load Balancer | ~$16/month |
| Public IPv4 addresses (nodes + NLB) | ~$0.005/hour each |

Roughly **$0.25/hour, about $6/day**. Create it, learn, then `terraform destroy` (step 9). Set an AWS Budget alert first.
Use `node_capacity_type = "SPOT"` to cut node cost. To stay within the true free tier, use the legacy k3s variant in `k3s/`.

Design choices that keep cost down: no NAT gateway (nodes sit in public subnets, their security group still blocks inbound internet traffic), 2 AZs, a single small node group. Production would use private subnets + NAT or VPC endpoints.

## Project layout
```
app/                 Node.js app + tests
Dockerfile           multi-stage, non-root
k8s-eks/             Kubernetes manifests (Deployment, Service/NLB, PDB, Namespace)
monitoring/          Helm values + install.sh for Prometheus and Grafana
bootstrap/           one-time Terraform: S3 bucket for remote state
terraform/           VPC, EKS, ECR, GitHub OIDC role
.github/workflows/   ci-cd.yml (EKS), terraform.yml (fmt/validate/Checkov), ci-cd-k3s.yml (manual, legacy)
k3s/                 low-cost k3s-on-EC2 variant (previous version)
```

## Prerequisites
- AWS account + CLI configured with admin-level credentials (`aws sts get-caller-identity` works)
- Terraform >= 1.10 (or OpenTofu), kubectl, Helm 3, git
- A GitHub account and an empty repository

## Step-by-step

### 1. Push the code to GitHub
```bash
cd k8s-sample-app
git init && git add . && git commit -m "initial commit"
git branch -M main
git remote add origin https://github.com/<user>/<repo>.git
git push -u origin main
```
The first pipeline run will test and scan, but it can't push to ECR until steps 2-4 are done.

### 2. Create the Terraform state bucket (once)
```bash
cd bootstrap
terraform init
terraform apply -var region=ap-southeast-1
terraform output state_bucket       # note the bucket name
cd ..
```

### 3. Create the infrastructure
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set region and github_repo = "<user>/<repo>"

terraform init \
  -backend-config="bucket=<state_bucket from step 2>" \
  -backend-config="key=sample-app/terraform.tfstate" \
  -backend-config="region=ap-southeast-1"

terraform plan
terraform apply          # EKS takes about 12-15 minutes
```
If your account already has the GitHub OIDC provider, set `create_github_oidc_provider = false`.
Note the outputs: `github_actions_role_arn`, `cluster_name`, `ecr_repository_url`.

### 4. Configure GitHub (Settings → Secrets and variables → Actions)
| Type | Name | Value |
|---|---|---|
| Secret | `AWS_ROLE_ARN` | `github_actions_role_arn` output |
| Variable | `AWS_REGION` | your region |
| Variable | `EKS_CLUSTER_NAME` | `cluster_name` output (`sample-app-eks`) |

Optional: create an Environment named `production` and add required reviewers to approve deployments.

### 5. Deploy the app
Re-run the workflow (Actions → CI/CD (EKS) → Run workflow) or push a commit. The pipeline:
1. runs unit tests
2. Trivy repo scan (dependencies, secrets, Dockerfile and K8s misconfigurations)
3. builds the image, Trivy image scan (fails on fixable HIGH/CRITICAL)
4. pushes to ECR with the git SHA as tag
5. assumes the AWS role via OIDC, runs `kubectl apply`, waits for the rollout

### 6. Verify
```bash
$(terraform output -raw configure_kubectl)       # same as: aws eks update-kubeconfig ...
kubectl get nodes
kubectl -n sample-app get pods
HOST=$(kubectl -n sample-app get svc sample-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$HOST/
curl -X POST http://$HOST/api/tasks -H 'Content-Type: application/json' -d '{"title":"hello eks"}'
curl http://$HOST/api/tasks
```
The NLB can take 2-3 minutes before DNS resolves.

### 7. Install monitoring
```bash
cd monitoring && ./install.sh
kubectl -n monitoring port-forward svc/grafana 3000:80
```
Open http://localhost:3000, user `admin`, password printed by the script. Dashboards "Node Exporter Full" and "Kubernetes / Views / Pods" are pre-loaded.
In Explore, try `rate(http_requests_total[1m])` or `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))`.
Metrics are not persisted (no volume); add the EBS CSI driver add-on if you want persistence.

### 8. Make a change and watch it roll out
Edit `app/server.js`, push to `main`, and watch `kubectl -n sample-app rollout status deployment/sample-app`.
Zero-downtime: `maxUnavailable: 0` plus readiness probes and a PodDisruptionBudget.

### 9. Destroy everything (stops billing)
```bash
kubectl delete -f k8s-eks/          # removes the NLB; otherwise VPC deletion can hang on leftover ENIs
helm uninstall grafana prometheus -n monitoring
cd terraform && terraform destroy
# optional, last: remove the state bucket (empty it first)
```

## Security notes
- **Trivy** (open source) gates every build. Run locally: `trivy fs .` and `trivy image sample-app:local`.
- **Checkov** (open source) scans Terraform in `terraform.yml`. It is advisory (`soft_fail`) so read its findings; typical ones are the public API endpoint and cluster logging.
- No long-lived AWS keys: GitHub OIDC role, restricted to this repo's `main` branch.
- The deploy role is cluster-admin on the cluster for simplicity. Tighten it to a namespace-scoped `AmazonEKSEditPolicy` for production.
- The EKS API endpoint is public (IAM-authenticated) because GitHub-hosted runners have changing IPs. Restrict `api_allowed_cidrs` if you use self-hosted runners.
- Pods run non-root, read-only root filesystem, all capabilities dropped. ECR tags are immutable and images are scanned on push.
- Pin third-party Actions to commit SHAs for production.

## Notes on what was and wasn't verified
The app tests pass, and the Terraform formatting and YAML/HCL syntax check out. The Terraform was **not** applied against a real AWS account and the pipeline was not run, so expect to fix small issues on the first run (module version drift, region-specific instance availability, Kubernetes version). Module versions are pinned with `~>` ranges in `terraform/vpc.tf` and `terraform/eks.tf`, and `cluster_version` is a variable: check the EKS docs for versions currently in standard support.

## Next steps
Private subnets + NAT, AWS Load Balancer Controller with an ALB Ingress and ACM certificate, Karpenter or cluster autoscaler, RDS/DynamoDB instead of the in-memory store, Alertmanager rules, Terraform plan/apply in CI with a dedicated infra role.
