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
  description = "ARN of the OIDC provider for the EKS cluster"
  value       = module.eks.oidc_provider_arn
}

output "vpc_id" {
  description = "ID of the VPC created for the eks-test-1 cluster"
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the eks-test-1 VPC (shared with peer clusters)"
  value       = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "List of IDs of the private subnets in the eks-test-1 VPC"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "List of IDs of the public subnets in the eks-test-1 VPC"
  value       = module.vpc.public_subnets
}

output "vpc_peering_connection_id" {
  description = "ID of the VPC peering connection between eks-test-1 and eks-ops"
  value       = aws_vpc_peering_connection_accepter.to_ops.id
}

output "node_security_group_id" {
  description = "Security group ID attached to the EKS managed node groups"
  value       = module.eks.node_security_group_id
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster control plane"
  value       = module.eks.cluster_security_group_id
}
