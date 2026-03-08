terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket         = "study-platform-terraform-state"
    key            = "eks-ops/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "study-platform-terraform-locks"
  }
}

provider "aws" {
  region = local.region

  default_tags {
    tags = local.tags
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
  }
}

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------
locals {
  cluster_name = "eks-ops"
  region       = "us-east-1"
  vpc_cidr     = "10.0.0.0/16"

  # Spread across 3 AZs in us-east-1
  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.0.0/19", "10.0.32.0/19", "10.0.64.0/19"]
  public_subnets  = ["10.0.96.0/24", "10.0.97.0/24", "10.0.98.0/24"]

  cluster_version = var.cluster_version

  tags = merge(var.tags, {
    "kubernetes.io/cluster/${local.cluster_name}" = "owned"
    Environment                                   = var.environment
  })
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.cluster_name}-vpc"
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Required tags for EKS to discover subnets for load balancers
  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# EKS Cluster
# ---------------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = local.cluster_version

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # Allow public access to API server (restrict to corp IPs in production)
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]
  cluster_endpoint_private_access      = true

  # Enable IRSA (IAM Roles for Service Accounts)
  enable_irsa = true

  # Core EKS managed add-ons
  cluster_addons = {
    vpc-cni = {
      most_recent              = true
      before_compute           = true
      service_account_role_arn = module.vpc_cni_irsa.iam_role_arn
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  # Managed node groups
  eks_managed_node_groups = {
    ops = {
      name           = "${local.cluster_name}-ops"
      instance_types = ["t3.medium"]

      min_size     = 2
      max_size     = 4
      desired_size = 2

      disk_size = 50

      # Use AL2 optimized AMI
      ami_type = "AL2_x86_64"

      labels = {
        role        = "ops"
        environment = var.environment
      }

      taints = []

      update_config = {
        max_unavailable_percentage = 33
      }

      tags = merge(local.tags, {
        "k8s.io/cluster-autoscaler/enabled"               = "true"
        "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
      })
    }
  }

  # Extend node security group rules to allow cross-cluster communication
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols (intra-cluster)"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    ingress_from_test1 = {
      description = "Allow ingress from eks-test-1 VPC for cross-cluster Istio/ArgoCD"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      cidr_blocks = ["10.1.0.0/16"]
    }
    ingress_from_test2 = {
      description = "Allow ingress from eks-test-2 VPC for cross-cluster Istio/ArgoCD"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      cidr_blocks = ["10.2.0.0/16"]
    }
    egress_all = {
      description = "Allow all egress"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# IRSA for VPC CNI (required for prefix delegation)
# ---------------------------------------------------------------------------
module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name_prefix      = "${local.cluster_name}-vpc-cni-"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# IRSA for EBS CSI Driver
# ---------------------------------------------------------------------------
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name_prefix      = "${local.cluster_name}-ebs-csi-"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# ECR Repository for the study-platform application
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "study_platform" {
  name                 = "study-platform"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.tags, {
    Name = "study-platform"
  })
}

resource "aws_ecr_lifecycle_policy" "study_platform" {
  repository = aws_ecr_repository.study_platform.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images older than 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# IRSA for ArgoCD — allows ArgoCD to call eks:DescribeCluster on test clusters
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "argocd_irsa_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:argocd:argocd-application-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "argocd_irsa" {
  name               = "${local.cluster_name}-argocd-irsa"
  assume_role_policy = data.aws_iam_policy_document.argocd_irsa_assume.json

  tags = merge(local.tags, {
    Name = "${local.cluster_name}-argocd-irsa"
  })
}

data "aws_iam_policy_document" "argocd_irsa_policy" {
  statement {
    sid    = "DescribeEKSClusters"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
      "eks:ListClusters",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AssumeRoleInPeerClusters"
    effect = "Allow"
    actions = [
      "sts:AssumeRole",
    ]
    # ArgoCD will assume a role in each peer cluster to apply manifests
    resources = [
      "arn:aws:iam::*:role/eks-test-1-argocd-spoke",
      "arn:aws:iam::*:role/eks-test-2-argocd-spoke",
    ]
  }
}

resource "aws_iam_role_policy" "argocd_irsa" {
  name   = "${local.cluster_name}-argocd-irsa-policy"
  role   = aws_iam_role.argocd_irsa.id
  policy = data.aws_iam_policy_document.argocd_irsa_policy.json
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC provider and IAM role for CI/CD
# ---------------------------------------------------------------------------
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]

  tags = merge(local.tags, {
    Name = "github-actions-oidc"
  })
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${local.cluster_name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json

  tags = merge(local.tags, {
    Name = "${local.cluster_name}-github-actions"
  })
}

data "aws_iam_policy_document" "github_actions_policy" {
  statement {
    sid    = "ECRAuth"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.study_platform.arn]
  }

  statement {
    sid    = "EKSDescribe"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
      "eks:ListClusters",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "SSMReadParams"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:aws:ssm:${local.region}:*:parameter/study-platform/*",
    ]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "${local.cluster_name}-github-actions-policy"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_policy.json
}

# ---------------------------------------------------------------------------
# SSM Parameter — store the cluster name for cross-stack references
# ---------------------------------------------------------------------------
resource "aws_ssm_parameter" "cluster_name" {
  name  = "/study-platform/eks-ops/cluster-name"
  type  = "String"
  value = module.eks.cluster_name

  tags = local.tags
}

resource "aws_ssm_parameter" "cluster_endpoint" {
  name  = "/study-platform/eks-ops/cluster-endpoint"
  type  = "String"
  value = module.eks.cluster_endpoint

  tags = local.tags
}

resource "aws_ssm_parameter" "vpc_id" {
  name  = "/study-platform/eks-ops/vpc-id"
  type  = "String"
  value = module.vpc.vpc_id

  tags = local.tags
}

resource "aws_ssm_parameter" "vpc_cidr" {
  name  = "/study-platform/eks-ops/vpc-cidr"
  type  = "String"
  value = local.vpc_cidr

  tags = local.tags
}
