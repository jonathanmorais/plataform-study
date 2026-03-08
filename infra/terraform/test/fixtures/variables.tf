variable "region" {
  description = "AWS region where fixture resources will be created"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the test EKS cluster created by the fixture"
  type        = string
  default     = "test-eks"
}

variable "environment" {
  description = "Environment label applied to all fixture resources via tags"
  type        = string
  default     = "test"
}

variable "cluster_version" {
  description = "Kubernetes version for the test EKS cluster"
  type        = string
  default     = "1.29"
}

variable "github_org" {
  description = "GitHub organisation used in the Actions OIDC trust policy"
  type        = string
  default     = "my-org"
}

variable "github_repo" {
  description = "GitHub repository name used in the Actions OIDC trust policy"
  type        = string
  default     = "plataform-study"
}
