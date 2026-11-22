data "aws_caller_identity" "current" {}

locals {
  cluster_name = "${var.project_name}-eks"
  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }
}
