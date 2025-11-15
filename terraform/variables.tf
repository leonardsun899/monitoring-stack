variable "aws_region" {
  description = "AWS 区域"
  type        = string
  default     = "ap-southeast-2"
}

variable "cluster_name" {
  description = "EKS 集群名称"
  type        = string
  default     = "eks-test"
}

variable "environment" {
  description = "环境名称（用于标签）"
  type        = string
  default     = "test"
}

variable "kubernetes_version" {
  description = "Kubernetes 版本"
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "VPC CIDR 块"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "可用区列表"
  type        = list(string)
  default     = ["ap-southeast-2a", "ap-southeast-2b", "ap-southeast-2c"]
}

variable "private_subnet_cidrs" {
  description = "私有子网 CIDR 列表"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "公有子网 CIDR 列表"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "node_min_size" {
  description = "节点组最小实例数"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "节点组最大实例数"
  type        = number
  default     = 3
}

variable "node_desired_size" {
  description = "节点组期望实例数"
  type        = number
  default     = 2
}

variable "node_instance_types" {
  description = "节点实例类型列表"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "loki_s3_bucket_name" {
  description = "Loki S3 存储桶名称（必须全局唯一）。如果为空，将自动生成"
  type        = string
  default     = "loki-test-storage"
}

variable "loki_retention_days" {
  description = "Loki 日志保留天数"
  type        = number
  default     = 30
}

