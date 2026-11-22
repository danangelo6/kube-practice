> **Legacy low-cost variant.** This is the k3s-on-EC2 path. The main project now targets EKS with Terraform (see the root README). Run the workflow manually from the Actions tab.

# Sample App: Docker + Kubernetes (k3s) + GitHub Actions on AWS Free Tier

A small Node.js "tasks" REST API with Prometheus metrics, containerized with Docker, scanned with **Trivy**,
pushed to **Amazon ECR**, and deployed to a **k3s** (lightweight Kubernetes) node on **EC2** by GitHub Actions.
Monitoring uses **Prometheus + Grafana**.

```
git push ──► GitHub Actions ──► test ─► Trivy (repo) ─► docker build ─► Trivy (image) ─► push to ECR
                                                                                           │
                                   AWS SSM Run Command (OIDC, no SSH keys) ◄───────────────┘
                                          │
                                          ▼
                              EC2 (t3.micro) running k3s
                              ├─ namespace sample-app : Deployment (2 pods) + Service + Ingress (Traefik :80)
                              └─ namespace monitoring : Prometheus + Grafana
```

## Why k3s on EC2 and not EKS?
EKS charges ~$0.10/hour for the control plane and is **not** part of the free tier. k3s is real, CNCF-certified
Kubernetes, so every manifest here works unchanged on EKS later.

## AWS services used
| Service | Purpose | Cost note |
|---|---|---|
| EC2 (t3.micro, or t2.micro where applicable) | Runs k3s | Free tier eligible instance types vary by account/region, so check the Free Tier page |
| ECR | Private Docker registry | Small free storage allowance; keep few images |
| IAM + OIDC provider | GitHub gets short-lived AWS credentials, no stored keys | Free |
| SSM (Systems Manager) | Run deploy commands on the node, no SSH/6443 exposure | Free |
| VPC / Security Group | Allow HTTP 80 only | Free |

> Always check your account's current free-tier terms and set a **AWS Budget alert** (e.g. $1). Stop/terminate the instance when done.

## Step-by-step deployment

Set these variables in your terminal first (AWS CLI v2 configured with an admin user):
```bash
export AWS_REGION=ap-southeast-1          # pick your region
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export GH_USER=<your-github-username>
export GH_REPO=<your-repo-name>
```

### 1. Push the code to GitHub
```bash
cd k8s-sample-app
git init && git add . && git commit -m "initial commit"
git branch -M main
git remote add origin https://github.com/$GH_USER/$GH_REPO.git
git push -u origin main      # the first run will fail at the AWS steps until you finish step 2-6; that's expected
```

### 2. Create the ECR repository
```bash
aws ecr create-repository --repository-name sample-app --region $AWS_REGION \
  --image-scanning-configuration scanOnPush=true
# keep only the last 5 images to stay within free storage
aws ecr put-lifecycle-policy --repository-name sample-app --region $AWS_REGION --lifecycle-policy-text '{
 "rules":[{"rulePriority":1,"description":"keep last 5","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":5},"action":{"type":"expire"}}]}'
```

### 3. Create the EC2 instance role (SSM + ECR pull)
```bash
aws iam create-role --role-name k3s-node-role --assume-role-policy-document file://k3s/aws/ec2-trust-policy.json
aws iam attach-role-policy --role-name k3s-node-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam attach-role-policy --role-name k3s-node-role --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
aws iam create-instance-profile --instance-profile-name k3s-node-profile
aws iam add-role-to-instance-profile --instance-profile-name k3s-node-profile --role-name k3s-node-role
```

### 4. Launch the EC2 instance
```bash
# Security group: HTTP only. No SSH needed (we use SSM).
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION)
SG_ID=$(aws ec2 create-security-group --group-name k3s-sg --description "k3s node" --vpc-id $VPC_ID --query GroupId --output text --region $AWS_REGION)
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $AWS_REGION

AMI=$(aws ssm get-parameter --region $AWS_REGION \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)

aws ec2 run-instances --region $AWS_REGION --image-id $AMI --instance-type t3.micro \
  --iam-instance-profile Name=k3s-node-profile --security-group-ids $SG_ID \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=20,VolumeType=gp3}' \
  --user-data file://k3s/scripts/ec2-user-data.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=k3s-node}]' \
  --query 'Instances[0].InstanceId' --output text
```
Save the instance ID: `export INSTANCE_ID=i-xxxxxxxx`. Wait about 3-5 minutes for k3s to install, then verify:
```bash
aws ssm start-session --target $INSTANCE_ID --region $AWS_REGION     # needs the Session Manager plugin
sudo kubectl get nodes        # should show Ready
```
If the instance type is not free-tier eligible for you, t3.small (2 GB RAM) is more comfortable and costs only a few dollars a month.

### 5. Let GitHub Actions assume an AWS role (OIDC)
```bash
# one time per AWS account
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com
```
Replace the `<PLACEHOLDERS>` in `k3s/aws/github-oidc-trust-policy.json` and `k3s/aws/github-deploy-policy.json`, then:
```bash
aws iam create-role --role-name github-deploy-role --assume-role-policy-document file://k3s/aws/github-oidc-trust-policy.json
aws iam put-role-policy --role-name github-deploy-role --policy-name deploy --policy-document file://k3s/aws/github-deploy-policy.json
echo arn:aws:iam::$ACCOUNT_ID:role/github-deploy-role
```

### 6. Add GitHub settings
In your repo: **Settings → Secrets and variables → Actions**
- Secret `AWS_ROLE_ARN` = the role ARN printed above
- Variable `AWS_REGION` = your region
- Variable `EC2_INSTANCE_ID` = your instance ID

### 7. Deploy
Push to `main` (or re-run the workflow). The pipeline runs tests, Trivy scans, builds, pushes to ECR, and deploys via SSM.
Open the app:
```bash
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $AWS_REGION \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
curl http://$PUBLIC_IP/
curl -X POST http://$PUBLIC_IP/api/tasks -H 'Content-Type: application/json' -d '{"title":"hello k8s"}'
curl http://$PUBLIC_IP/api/tasks
```

### 8. Install monitoring (Prometheus + Grafana)
Open an SSM session on the node and run:
```bash
sudo dnf install -y git
git clone https://github.com/$GH_USER/$GH_REPO.git && cd $GH_REPO/monitoring
sudo ../k3s/scripts/install-monitoring.sh
```
(Edit the Grafana admin password in `monitoring/grafana-values.yaml` first.)
Access Grafana privately through an SSM tunnel from your laptop:
```bash
aws ssm start-session --target $INSTANCE_ID --region $AWS_REGION \
  --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
```
On the node, forward the service first: `sudo kubectl -n monitoring port-forward --address 127.0.0.1 svc/grafana 3000:80`.
Then browse to http://localhost:3000. Prometheus already scrapes the app's `/metrics` through pod annotations; try
`rate(http_requests_total[1m])` in Grafana Explore.

### 9. Clean up (avoid charges)
```bash
aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $AWS_REGION
aws ecr delete-repository --repository-name sample-app --force --region $AWS_REGION
```

## Security scanning
- **Trivy** (Aqua Security, open source) runs twice in CI: repo scan (dependency CVEs, secrets, Dockerfile/K8s misconfigurations) and image scan. HIGH/CRITICAL fixable findings fail the build.
- Run locally: `trivy fs .` and `trivy image sample-app:local`.
- Good additions: **Hadolint** (Dockerfile lint), **Checkov** or **kube-linter** (K8s manifests), **Dependabot** (dependency updates).
- Hardening in place: non-root container, read-only root FS, dropped capabilities, no stored AWS keys, no open SSH, OIDC role limited to the `main` branch.
- For production, pin GitHub Actions to commit SHAs.

## Local run
```bash
docker build -t sample-app:local .
docker run --rm -p 3000:3000 sample-app:local
curl localhost:3000/health
```

## Troubleshooting
- Pods `ImagePullBackOff`: the ECR secret is refreshed on each deploy (tokens last 12h); re-run the workflow.
- Node out of memory: use t3.small, or lower Prometheus retention/disable kube-state-metrics.
- SSM command can't find instance: check the instance role and that the SSM Agent shows "Online" in Systems Manager → Fleet Manager.

## Next steps
Replace the in-memory store with RDS or DynamoDB, add HTTPS (cert-manager + a domain), move to EKS, add Alertmanager rules.
