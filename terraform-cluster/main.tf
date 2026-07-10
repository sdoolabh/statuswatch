# statuswatch CLUSTER stack — the destroyable portfolio layer.
# Separate state from the persistent pipeline ON PURPOSE: `terraform destroy`
# here removes EKS, the VPC peering, and the DB access rule, and cannot touch
# RDS, S3, Lambdas, or the public site. Run it business-hours, kill it at
# night, rebuild at will — the data layer never notices.

terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "shanedoolabh-statuswatch-tfstate"
    key          = "cluster/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.80" }
    helm       = { source = "hashicorp/helm", version = "~> 2.16" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.35" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "statuswatch", Lifecycle = "cluster-cattle", ManagedBy = "terraform" }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "domain" {
  type    = string
  default = "shanedoolabh.com"
}

variable "gitops_repo_url" {
  description = "HTTPS URL of the statuswatch repo (public) — ArgoCD's source of truth"
  type        = string
  # e.g. "https://github.com/<you>/statuswatch.git"
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

# The contract with the persistent stack:
data "terraform_remote_state" "persistent" {
  backend = "s3"
  config = {
    bucket = "shanedoolabh-statuswatch-tfstate"
    key    = "persistent/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  p = data.terraform_remote_state.persistent.outputs
}

data "aws_route53_zone" "root" {
  name         = var.domain
  private_zone = false
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}
