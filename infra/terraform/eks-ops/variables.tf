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
  default     = "ops"
}

variable "tags" {
  description = "A map of tags to apply to all resources"
  type        = map(string)
  default = {
    Project     = "study-platform"
    ManagedBy   = "terraform"
    Environment = "ops"
    Owner       = "platform-team"
  }
}

variable "github_org" {
  description = "GitHub organization or user name used for OIDC trust policy"
  type        = string
  default     = "my-org"
}

variable "github_repo" {
  description = "GitHub repository name used for OIDC trust policy"
  type        = string
  default     = "plataform-study"
}
