variable "aws_region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "us-east-1"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.29"
}

variable "environment" {
  description = "Environment name used for tagging and naming resources"
  type        = string
  default     = "production"
}

variable "tags" {
  description = "A map of tags to apply to all resources"
  type        = map(string)
  default = {
    Project     = "study-platform"
    ManagedBy   = "terraform"
    Environment = "production"
    Owner       = "platform-team"
  }
}

variable "ops_vpc_id" {
  description = "VPC ID of the eks-ops cluster used to establish VPC peering"
  type        = string
}

variable "ops_vpc_cidr" {
  description = "CIDR block of the eks-ops VPC — added to route tables for management traffic"
  type        = string
  default     = "10.0.0.0/16"
}

variable "test1_vpc_id" {
  description = "VPC ID of the eks-test-1 (staging) cluster used to establish VPC peering for Istio cross-cluster"
  type        = string
}

variable "test1_vpc_cidr" {
  description = "CIDR block of the eks-test-1 VPC — added to route tables for Istio cross-cluster traffic"
  type        = string
  default     = "10.1.0.0/16"
}
