variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Prefix for resource names"
  type        = string
  default     = "sample-app"
}

variable "github_repo" {
  description = "GitHub repository allowed to deploy, as owner/repo"
  type        = string
}

variable "create_github_oidc_provider" {
  description = "Set false if the GitHub OIDC provider already exists in this AWS account"
  type        = bool
  default     = true
}

variable "cluster_version" {
  description = "EKS Kubernetes version (check the EKS docs for versions in standard support)"
  type        = string
  default     = "1.35"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "node_instance_type" {
  description = "Worker node size. t3.medium allows ~17 pods per node; t3.small only ~11."
  type        = string
  default     = "t3.medium"
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT (SPOT is cheaper but nodes can be reclaimed)"
  type        = string
  default     = "ON_DEMAND"
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API. GitHub-hosted runners use changing IPs, so 0.0.0.0/0 is needed for the CI deploy; access is still IAM-authenticated."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
