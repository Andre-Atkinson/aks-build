terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Auth comes from the standard AWS credential chain (`aws configure` / SSO /
# env vars) - no long-lived keys are created or stored by this build.
provider "aws" {
  region = var.region
}

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  name = "k10dr${random_id.suffix.hex}"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = "10.90.0.0/16"

  azs             = ["${var.region}a", "${var.region}b"]
  private_subnets = ["10.90.1.0/24", "10.90.2.0/24"]
  public_subnets  = ["10.90.101.0/24", "10.90.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Required by the EKS load balancer controller / ingress to auto-discover subnets.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = {
    environment = "k10-dr-demo"
  }
}

# EKS Pod Identity role for the EBS CSI driver addon - avoids static AWS keys
# and avoids standing up an OIDC/IRSA provider just for this one addon.
resource "aws_iam_role" "ebs_csi" {
  name = "${local.name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access = true

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_type
      min_size       = 1
      max_size       = var.node_desired_size + 1
      desired_size   = var.node_desired_size
    }
  }

  # K10 needs: (1) the EBS CSI driver to snapshot/provision volumes, and
  # (2) the external-snapshotter CRDs/controller (installed separately in
  # infra/kasten-aws, since EKS does not ship them by default).
  addons = {
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
    eks-pod-identity-agent = {}
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
  }

  tags = {
    environment = "k10-dr-demo"
  }
}
