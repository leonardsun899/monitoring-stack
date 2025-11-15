variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-2"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "eks-test"
}

variable "environment" {
  description = "Environment name (for tagging)"
  type        = string
  default     = "test"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
  default     = ["ap-southeast-2a", "ap-southeast-2b", "ap-southeast-2c"]
}

variable "private_subnet_cidrs" {
  description = "List of private subnet CIDRs"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "List of public subnet CIDRs"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "node_min_size" {
  description = "Minimum number of instances in node group"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of instances in node group"
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Desired number of instances in node group"
  type        = number
  default     = 4
}

variable "node_instance_types" {
  description = "List of node instance types"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "loki_s3_bucket_name" {
  description = "Loki S3 bucket name (must be globally unique). If empty, will be auto-generated"
  type        = string
  default     = "" # Empty by default to auto-generate unique name
}

variable "loki_retention_days" {
  description = "Loki log retention days"
  type        = number
  default     = 30
}

variable "create_kubernetes_resources" {
  description = "Whether to create Kubernetes namespace and ServiceAccount in Terraform. If false, create them manually or let ArgoCD create the namespace. Recommended: false to avoid timeout issues"
  type        = bool
  default     = false # Default to false to avoid timeout issues
}

variable "create_loadbalancer_services" {
  description = "Whether to create LoadBalancer services in Terraform. This ensures LoadBalancers are deleted during terraform destroy. Recommended: true"
  type        = bool
  default     = true
}

