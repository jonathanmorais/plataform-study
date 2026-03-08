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
  }

  backend "s3" {
    bucket         = "study-platform-terraform-state"
    key            = "eks-test-2/terraform.tfstate"
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
  cluster_name = "eks-test-2"
  region       = "us-east-1"
  vpc_cidr     = "10.2.0.0/16"

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.2.0.0/19", "10.2.32.0/19", "10.2.64.0/19"]
  public_subnets  = ["10.2.96.0/24", "10.2.97.0/24", "10.2.98.0/24"]

  cluster_version = var.cluster_version

  tags = merge(var.tags, {
    "kubernetes.io/cluster/${local.cluster_name}" = "owned"
    Environment                                   = var.environment
  })
}

# ---------------------------------------------------------------------------
# SSM parameter — custom EKS-optimised AMI
# ---------------------------------------------------------------------------
data "aws_ssm_parameter" "eks_ami" {
  name = "/aws/service/eks/optimized-ami/${local.cluster_version}/amazon-linux-2/recommended/image_id"
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
# VPC Peering — accepter side for connection from eks-ops
# ---------------------------------------------------------------------------
data "aws_vpc_peering_connection" "from_ops" {
  filters = [
    {
      name   = "accepter-vpc-info.vpc-id"
      values = [module.vpc.vpc_id]
    },
    {
      name   = "requester-vpc-info.vpc-id"
      values = [var.ops_vpc_id]
    },
    {
      name   = "status-code"
      values = ["pending-acceptance", "active"]
    },
  ]

  depends_on = [module.vpc]
}

resource "aws_vpc_peering_connection_accepter" "to_ops" {
  vpc_peering_connection_id = data.aws_vpc_peering_connection.from_ops.id
  auto_accept               = true

  tags = merge(local.tags, {
    Name = "${local.cluster_name}-to-eks-ops-peering"
    Side = "accepter"
  })
}

# ---------------------------------------------------------------------------
# VPC Peering — accepter side for connection from eks-test-1 (Istio cross-cluster)
# ---------------------------------------------------------------------------
data "aws_vpc_peering_connection" "from_test1" {
  filters = [
    {
      name   = "accepter-vpc-info.vpc-id"
      values = [module.vpc.vpc_id]
    },
    {
      name   = "requester-vpc-info.vpc-id"
      values = [var.test1_vpc_id]
    },
    {
      name   = "status-code"
      values = ["pending-acceptance", "active"]
    },
  ]

  depends_on = [module.vpc]
}

resource "aws_vpc_peering_connection_accepter" "to_test1" {
  vpc_peering_connection_id = data.aws_vpc_peering_connection.from_test1.id
  auto_accept               = true

  tags = merge(local.tags, {
    Name = "${local.cluster_name}-to-eks-test-1-peering"
    Side = "accepter"
  })
}

# ---------------------------------------------------------------------------
# Route table entries — ops traffic
# ---------------------------------------------------------------------------
resource "aws_route" "private_to_ops" {
  count = length(module.vpc.private_route_table_ids)

  route_table_id            = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block    = var.ops_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.to_ops.id
}

resource "aws_route" "public_to_ops" {
  route_table_id            = module.vpc.public_route_table_ids[0]
  destination_cidr_block    = var.ops_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.to_ops.id
}

# ---------------------------------------------------------------------------
# Route table entries — staging (test-1) traffic for Istio cross-cluster
# ---------------------------------------------------------------------------
resource "aws_route" "private_to_test1" {
  count = length(module.vpc.private_route_table_ids)

  route_table_id            = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block    = var.test1_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.to_test1.id
}

resource "aws_route" "public_to_test1" {
  route_table_id            = module.vpc.public_route_table_ids[0]
  destination_cidr_block    = var.test1_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.to_test1.id
}

# ---------------------------------------------------------------------------
# Launch template — IMDSv2, encrypted gp3, stricter production defaults
# ---------------------------------------------------------------------------
resource "aws_launch_template" "prod" {
  name_prefix   = "${local.cluster_name}-"
  image_id      = data.aws_ssm_parameter.eks_ami.value
  instance_type = "m5.large"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 mandatory in production
    http_put_response_hop_limit = 1          # Tighter hop limit for prod
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      delete_on_termination = true
      encrypted             = true
    }
  }

  monitoring {
    enabled = true
  }

  # Disable public IP assignment on all instances
  network_interfaces {
    associate_public_ip_address = false
    delete_on_termination       = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.tags, {
      Name = "${local.cluster_name}-node"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.tags, {
      Name = "${local.cluster_name}-node-volume"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
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

  # Production: private-only API endpoint; access only via VPN or bastion
  cluster_endpoint_public_access  = false
  cluster_endpoint_private_access = true

  enable_irsa = true

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

  eks_managed_node_groups = {
    prod = {
      name           = "${local.cluster_name}-prod"
      instance_types = ["m5.large"]

      min_size     = 3
      max_size     = 10
      desired_size = 3

      ami_type = "CUSTOM"

      launch_template = {
        id      = aws_launch_template.prod.id
        version = aws_launch_template.prod.latest_version
      }

      labels = {
        role        = "prod"
        environment = var.environment
      }

      # Taint nodes to require explicit scheduling tolerations in prod
      taints = [
        {
          key    = "dedicated"
          value  = "production"
          effect = "NO_SCHEDULE"
        }
      ]

      update_config = {
        max_unavailable_percentage = 20 # More conservative rolling update in prod
      }

      tags = merge(local.tags, {
        "k8s.io/cluster-autoscaler/enabled"               = "true"
        "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
      })
    }
  }

  # Strict security group rules for production — no wide ingress
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols (intra-cluster)"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    ingress_from_ops_management = {
      description = "Allow management traffic from eks-ops (ArgoCD, Rundeck)"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "ingress"
      cidr_blocks = [var.ops_vpc_cidr]
    }
    ingress_from_ops_kubelet = {
      description = "Allow kubelet API access from eks-ops management plane"
      protocol    = "tcp"
      from_port   = 10250
      to_port     = 10250
      type        = "ingress"
      cidr_blocks = [var.ops_vpc_cidr]
    }
    ingress_from_test1_istio = {
      description = "Allow Istio cross-cluster traffic from eks-test-1"
      protocol    = "tcp"
      from_port   = 15443
      to_port     = 15443
      type        = "ingress"
      cidr_blocks = [var.test1_vpc_cidr]
    }
    ingress_from_test1_istio_pilot = {
      description = "Allow Istio pilot discovery from eks-test-1"
      protocol    = "tcp"
      from_port   = 15012
      to_port     = 15012
      type        = "ingress"
      cidr_blocks = [var.test1_vpc_cidr]
    }
    egress_https = {
      description = "Allow HTTPS egress (ECR, S3, AWS APIs)"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "egress"
      cidr_blocks = ["0.0.0.0/0"]
    }
    egress_dns_udp = {
      description = "Allow DNS egress (UDP)"
      protocol    = "udp"
      from_port   = 53
      to_port     = 53
      type        = "egress"
      cidr_blocks = ["0.0.0.0/0"]
    }
    egress_dns_tcp = {
      description = "Allow DNS egress (TCP)"
      protocol    = "tcp"
      from_port   = 53
      to_port     = 53
      type        = "egress"
      cidr_blocks = ["0.0.0.0/0"]
    }
    egress_to_peers = {
      description = "Allow egress to peer VPCs (ops and staging)"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"
      cidr_blocks = [var.ops_vpc_cidr, var.test1_vpc_cidr]
    }
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# IRSA for VPC CNI
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
# ArgoCD spoke role — trusted by the ArgoCD IRSA role in eks-ops
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "argocd_spoke_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/eks-ops-argocd-irsa"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "argocd_spoke" {
  name               = "${local.cluster_name}-argocd-spoke"
  assume_role_policy = data.aws_iam_policy_document.argocd_spoke_assume.json

  tags = merge(local.tags, {
    Name = "${local.cluster_name}-argocd-spoke"
  })
}

resource "aws_iam_role_policy_attachment" "argocd_spoke_eks_readonly" {
  role       = aws_iam_role.argocd_spoke.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---------------------------------------------------------------------------
# SSM parameters — store outputs for cross-stack references
# ---------------------------------------------------------------------------
resource "aws_ssm_parameter" "cluster_name" {
  name  = "/study-platform/eks-test-2/cluster-name"
  type  = "String"
  value = module.eks.cluster_name

  tags = local.tags
}

resource "aws_ssm_parameter" "cluster_endpoint" {
  name  = "/study-platform/eks-test-2/cluster-endpoint"
  type  = "String"
  value = module.eks.cluster_endpoint

  tags = local.tags
}

resource "aws_ssm_parameter" "vpc_id" {
  name  = "/study-platform/eks-test-2/vpc-id"
  type  = "String"
  value = module.vpc.vpc_id

  tags = local.tags
}

resource "aws_ssm_parameter" "vpc_cidr" {
  name  = "/study-platform/eks-test-2/vpc-cidr"
  type  = "String"
  value = local.vpc_cidr

  tags = local.tags
}
