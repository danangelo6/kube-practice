data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# Cost-saving design: public subnets only, NO NAT gateway (~$32/month each).
# Nodes get public IPs but the node security group still blocks inbound traffic from the internet.
# For production, use private subnets for nodes plus NAT gateways or VPC endpoints.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets          = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  enable_nat_gateway      = false
  enable_dns_hostnames    = true
  map_public_ip_on_launch = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}
