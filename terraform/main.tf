# statuswatch Phase 2 — the always-on pipeline. Everything here is
# PERSISTENT: this is the layer that must never blink (see architecture doc).
# EKS/portfolio layer arrives in Phase 4 as a separate, destroyable stack.

terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "CHANGEME-statuswatch-tfstate"
    key          = "persistent/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "statuswatch", Lifecycle = "persistent", ManagedBy = "terraform" }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "poll_rate_minutes" {
  type    = number
  default = 2
}

data "aws_caller_identity" "current" {}
