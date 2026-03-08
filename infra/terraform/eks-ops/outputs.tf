output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint URL for the EKS cluster API server"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for the cluster CA"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_oidc_issuer_url" {
  description = "The URL of the OpenID Connect issuer for the EKS cluster (used for IRSA)"
  value       = module.eks.cluster_oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider for the EKS cluster (used for IRSA IAM policies)"
  value       = module.eks.oidc_provider_arn
}

output "vpc_id" {
  description = "ID of the VPC created for the eks-ops cluster"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "List of IDs of the private subnets in the eks-ops VPC"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "List of IDs of the public subnets in the eks-ops VPC"
  value       = module.vpc.public_subnets
}

output "vpc_cidr_block" {
  description = "CIDR block of the eks-ops VPC (used by peer clusters for route tables)"
  value       = module.vpc.vpc_cidr_block
}

output "ecr_repository_url" {
  description = "URL of the ECR repository for the study-platform application image"
  value       = aws_ecr_repository.study_platform.repository_url
}

output "ecr_repository_arn" {
  description = "ARN of the ECR repository for the study-platform application image"
  value       = aws_ecr_repository.study_platform.arn
}

output "argocd_irsa_role_arn" {
  description = "ARN of the IAM role used by ArgoCD via IRSA to describe EKS clusters"
  value       = aws_iam_role.argocd_irsa.arn
}

output "github_actions_oidc_role_arn" {
  description = "ARN of the IAM role assumed by GitHub Actions for CI/CD pipelines"
  value       = aws_iam_role.github_actions.arn
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster control plane"
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group ID attached to the EKS managed node groups"
  value       = module.eks.node_security_group_id
}
