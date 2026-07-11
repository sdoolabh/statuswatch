# Same cost posture as the pipeline: public subnets, no NAT (~$35/mo saved),
# spot nodes. Documented tradeoff; prod answer is private subnets + NAT.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.16"

  name = "statuswatch-cluster"
  cidr = "10.42.0.0/16" # must not overlap 10.61.0.0/16 (data VPC) — peering!

  azs            = ["${var.region}a", "${var.region}b"]
  public_subnets = ["10.42.0.0/20", "10.42.16.0/20"]

  enable_nat_gateway      = false
  map_public_ip_on_launch = true
  enable_dns_hostnames    = true

  public_subnet_tags = { "kubernetes.io/role/elb" = "1" }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = "statuswatch"
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        env = { ENABLE_PREFIX_DELEGATION = "true" }
      })
    }
    eks-pod-identity-agent = {}
  }

  eks_managed_node_groups = {
    default-v2 = {
      instance_types = ["t3.small", "t3a.small"]
      capacity_type  = "SPOT"
      min_size       = 3
      desired_size   = 4
      max_size       = 5
      subnet_ids     = module.vpc.public_subnets
    }
  }
}
