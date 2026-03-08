###############################################################################
# Fixture outputs — consumed by Terratest via terraform.Output()
###############################################################################

# ── EKS cluster ──────────────────────────────────────────────────────────────

output "cluster_name" {
  description = "Name of the test EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "API server endpoint URL of the test EKS cluster"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "Kubernetes version of the test EKS cluster"
  value       = aws_eks_cluster.main.version
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL of the test EKS cluster"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for the test EKS cluster"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "node_group_name" {
  description = "Name of the managed node group"
  value       = aws_eks_node_group.main.node_group_name
}

output "node_group_role_arn" {
  description = "ARN of the IAM role used by the managed node group"
  value       = aws_iam_role.eks_node_group.arn
}

# ── VPC ──────────────────────────────────────────────────────────────────────

output "ops_vpc_id" {
  description = "ID of the ops VPC"
  value       = aws_vpc.ops.id
}

output "ops_vpc_cidr" {
  description = "CIDR block of the ops VPC"
  value       = aws_vpc.ops.cidr_block
}

output "test1_vpc_id" {
  description = "ID of the test-1 VPC"
  value       = aws_vpc.test1.id
}

output "test1_vpc_cidr" {
  description = "CIDR block of the test-1 VPC"
  value       = aws_vpc.test1.cidr_block
}

output "test2_vpc_id" {
  description = "ID of the test-2 VPC"
  value       = aws_vpc.test2.id
}

output "test2_vpc_cidr" {
  description = "CIDR block of the test-2 VPC"
  value       = aws_vpc.test2.cidr_block
}

output "private_subnet_ids" {
  description = "List of private subnet IDs in the ops VPC (tagged for internal-elb)"
  value       = aws_subnet.ops_private[*].id
}

# ── IAM ──────────────────────────────────────────────────────────────────────

output "github_actions_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider registered in IAM"
  value       = aws_iam_openid_connect_provider.github_actions.arn
}

output "github_actions_oidc_role_arn" {
  description = "ARN of the IAM role assumed by GitHub Actions runners"
  value       = aws_iam_role.github_actions.arn
}

output "argocd_irsa_role_arn" {
  description = "ARN of the IAM role used by ArgoCD via IRSA"
  value       = aws_iam_role.argocd_irsa.arn
}

# ── ECR ──────────────────────────────────────────────────────────────────────

output "ecr_repository_url" {
  description = "URL of the study-platform ECR repository"
  value       = aws_ecr_repository.study_platform.repository_url
}

output "ecr_repository_arn" {
  description = "ARN of the study-platform ECR repository"
  value       = aws_ecr_repository.study_platform.arn
}

# ── SSM ──────────────────────────────────────────────────────────────────────

output "ssm_ami_parameter_name" {
  description = "SSM parameter name that holds the latest EKS node AMI ID"
  value       = aws_ssm_parameter.ami_latest.name
}
