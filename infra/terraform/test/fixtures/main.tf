###############################################################################
# Terratest Fixture — study-platform infra tests
#
# Purpose: provision minimal, ephemeral AWS resources against which the Go
#          Terratest suite in infra/terraform/test/ runs assertions.
#
# Design decisions:
#   - Uses real AWS resources (not mocks) to verify actual AWS API behaviour.
#   - Resources are tagged with Environment=test and ManagedBy=terratest so
#     they can be identified and cleaned up even if `terraform destroy` fails.
#   - Node group uses t3.medium with a min/desired/max of 1/1/1 to keep costs
#     low during the short window the fixture is live.
#   - VPC peering is created between the three fixture VPCs to mirror the
#     production topology (eks-ops ↔ eks-test-1, eks-ops ↔ eks-test-2).
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

###############################################################################
# Locals
###############################################################################

locals {
  common_tags = {
    Project     = "study-platform"
    ManagedBy   = "terratest"
    Environment = var.environment
    Owner       = "platform-team"
  }

  # CIDR blocks are non-overlapping so VPC peering route tables don't conflict.
  ops_cidr   = "10.0.0.0/16"
  test1_cidr = "10.1.0.0/16"
  test2_cidr = "10.2.0.0/16"
}

###############################################################################
# Data sources
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

###############################################################################
# VPCs
# Three separate VPCs mirror the production cluster topology.
###############################################################################

# ── ops VPC ──────────────────────────────────────────────────────────────────
resource "aws_vpc" "ops" {
  cidr_block           = local.ops_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.cluster_name}-ops-vpc"
  }
}

resource "aws_internet_gateway" "ops" {
  vpc_id = aws_vpc.ops.id

  tags = {
    Name = "${var.cluster_name}-ops-igw"
  }
}

resource "aws_subnet" "ops_public" {
  count             = 2
  vpc_id            = aws_vpc.ops.id
  cidr_block        = cidrsubnet(local.ops_cidr, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.cluster_name}-ops-public-${count.index}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "ops_private" {
  count             = 2
  vpc_id            = aws_vpc.ops.id
  cidr_block        = cidrsubnet(local.ops_cidr, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name                              = "${var.cluster_name}-ops-private-${count.index}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_eip" "ops_nat" {
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-ops-nat-eip"
  }
}

resource "aws_nat_gateway" "ops" {
  allocation_id = aws_eip.ops_nat.id
  subnet_id     = aws_subnet.ops_public[0].id

  depends_on = [aws_internet_gateway.ops]

  tags = {
    Name = "${var.cluster_name}-ops-nat"
  }
}

resource "aws_route_table" "ops_public" {
  vpc_id = aws_vpc.ops.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ops.id
  }

  tags = {
    Name = "${var.cluster_name}-ops-public-rt"
  }
}

resource "aws_route_table_association" "ops_public" {
  count          = length(aws_subnet.ops_public)
  subnet_id      = aws_subnet.ops_public[count.index].id
  route_table_id = aws_route_table.ops_public.id
}

resource "aws_route_table" "ops_private" {
  vpc_id = aws_vpc.ops.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.ops.id
  }

  tags = {
    Name = "${var.cluster_name}-ops-private-rt"
  }
}

resource "aws_route_table_association" "ops_private" {
  count          = length(aws_subnet.ops_private)
  subnet_id      = aws_subnet.ops_private[count.index].id
  route_table_id = aws_route_table.ops_private.id
}

# ── test-1 VPC ───────────────────────────────────────────────────────────────
resource "aws_vpc" "test1" {
  cidr_block           = local.test1_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.cluster_name}-test1-vpc"
  }
}

resource "aws_subnet" "test1_private" {
  count             = 2
  vpc_id            = aws_vpc.test1.id
  cidr_block        = cidrsubnet(local.test1_cidr, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name                              = "${var.cluster_name}-test1-private-${count.index}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_route_table" "test1_private" {
  vpc_id = aws_vpc.test1.id

  tags = {
    Name = "${var.cluster_name}-test1-private-rt"
  }
}

resource "aws_route_table_association" "test1_private" {
  count          = length(aws_subnet.test1_private)
  subnet_id      = aws_subnet.test1_private[count.index].id
  route_table_id = aws_route_table.test1_private.id
}

# ── test-2 VPC ───────────────────────────────────────────────────────────────
resource "aws_vpc" "test2" {
  cidr_block           = local.test2_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.cluster_name}-test2-vpc"
  }
}

resource "aws_subnet" "test2_private" {
  count             = 2
  vpc_id            = aws_vpc.test2.id
  cidr_block        = cidrsubnet(local.test2_cidr, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name                              = "${var.cluster_name}-test2-private-${count.index}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_route_table" "test2_private" {
  vpc_id = aws_vpc.test2.id

  tags = {
    Name = "${var.cluster_name}-test2-private-rt"
  }
}

resource "aws_route_table_association" "test2_private" {
  count          = length(aws_subnet.test2_private)
  subnet_id      = aws_subnet.test2_private[count.index].id
  route_table_id = aws_route_table.test2_private.id
}

###############################################################################
# VPC Peering — ops ↔ test-1 and ops ↔ test-2
###############################################################################

resource "aws_vpc_peering_connection" "ops_to_test1" {
  vpc_id      = aws_vpc.ops.id
  peer_vpc_id = aws_vpc.test1.id
  auto_accept = true

  accepter {
    allow_remote_vpc_dns_resolution = true
  }

  requester {
    allow_remote_vpc_dns_resolution = true
  }

  tags = {
    Name = "${var.cluster_name}-ops-to-test1-peering"
  }
}

resource "aws_vpc_peering_connection" "ops_to_test2" {
  vpc_id      = aws_vpc.ops.id
  peer_vpc_id = aws_vpc.test2.id
  auto_accept = true

  accepter {
    allow_remote_vpc_dns_resolution = true
  }

  requester {
    allow_remote_vpc_dns_resolution = true
  }

  tags = {
    Name = "${var.cluster_name}-ops-to-test2-peering"
  }
}

# Routes in ops private route table → test-1 and test-2 CIDRs.
resource "aws_route" "ops_to_test1" {
  route_table_id            = aws_route_table.ops_private.id
  destination_cidr_block    = local.test1_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.ops_to_test1.id
}

resource "aws_route" "ops_to_test2" {
  route_table_id            = aws_route_table.ops_private.id
  destination_cidr_block    = local.test2_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.ops_to_test2.id
}

# Routes in test-1 private route table → ops CIDR.
resource "aws_route" "test1_to_ops" {
  route_table_id            = aws_route_table.test1_private.id
  destination_cidr_block    = local.ops_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.ops_to_test1.id
}

# Routes in test-2 private route table → ops CIDR.
resource "aws_route" "test2_to_ops" {
  route_table_id            = aws_route_table.test2_private.id
  destination_cidr_block    = local.ops_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.ops_to_test2.id
}

###############################################################################
# IAM — EKS cluster role
###############################################################################

data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

###############################################################################
# IAM — EKS node group role
###############################################################################

data "aws_iam_policy_document" "eks_node_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "eks_node_group" {
  name               = "${var.cluster_name}-node-group-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume.json
}

resource "aws_iam_role_policy_attachment" "worker_node" {
  role       = aws_iam_role.eks_node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "cni" {
  role       = aws_iam_role.eks_node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.eks_node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

###############################################################################
# EKS Cluster
###############################################################################

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = aws_subnet.ops_private[*].id
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]
}

###############################################################################
# OIDC Provider — EKS cluster (required for IRSA)
###############################################################################

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

###############################################################################
# EKS Managed Node Group
###############################################################################

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-node-group"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = aws_subnet.ops_private[*].id

  instance_types = ["t3.medium"]

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }

  # Allow the node group to be replaced without draining, acceptable in tests.
  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.worker_node,
    aws_iam_role_policy_attachment.cni,
    aws_iam_role_policy_attachment.ecr_read,
  ]
}

###############################################################################
# IAM — GitHub Actions OIDC provider
###############################################################################

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

###############################################################################
# IAM — GitHub Actions role (OIDC federation)
###############################################################################

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
  name               = "${var.cluster_name}-github-actions-role"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "ecr-push"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = "*"
      },
    ]
  })
}

###############################################################################
# IAM — ArgoCD IRSA role
###############################################################################

data "aws_iam_policy_document" "argocd_irsa_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:argocd:argocd-application-controller"]
    }
  }
}

resource "aws_iam_role" "argocd_irsa" {
  name               = "${var.cluster_name}-argocd-irsa-role"
  assume_role_policy = data.aws_iam_policy_document.argocd_irsa_assume.json
}

resource "aws_iam_role_policy" "argocd_eks_describe" {
  name = "eks-describe"
  role = aws_iam_role.argocd_irsa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
        ]
        Resource = "*"
      },
    ]
  })
}

###############################################################################
# ECR — study-platform image repository
###############################################################################

resource "aws_ecr_repository" "study_platform" {
  name                 = "study-platform"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "study_platform" {
  repository = aws_ecr_repository.study_platform.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the last 10 images; expire older ones to control storage cost"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      },
    ]
  })
}

###############################################################################
# SSM Parameters — AMI handoff (mirrors the Ansible → Terraform handoff path)
###############################################################################

resource "aws_ssm_parameter" "ami_latest" {
  name  = "/study-platform/eks/ami/latest"
  type  = "String"
  value = "ami-0placeholder00000001"

  tags = {
    Description = "Latest EKS node AMI — written by Ansible AMI build, read by Terraform"
  }
}

resource "aws_ssm_parameter" "ami_version" {
  name  = "/study-platform/eks/ami/version"
  type  = "String"
  value = "0.0.1-test"
}
