terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

# 配置 AWS Provider
provider "aws" {
  region = var.aws_region
}

# 获取当前 AWS 账户信息
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# 如果未指定存储桶名称，自动生成一个
locals {
  loki_bucket_name = var.loki_s3_bucket_name != "" ? var.loki_s3_bucket_name : "${var.cluster_name}-loki-storage-${random_id.bucket_suffix.hex}"
}

# 随机后缀，用于确保存储桶名称唯一
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# 创建 EKS 集群
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # 启用 IRSA
  enable_irsa = true

  # 节点组配置
  eks_managed_node_groups = {
    main = {
      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      # 节点标签
      labels = {
        Environment = var.environment
      }
    }
  }

  # 集群标签
  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# 创建 VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway   = true
  enable_vpn_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# 创建 S3 存储桶用于 Loki
resource "aws_s3_bucket" "loki_storage" {
  bucket = local.loki_bucket_name

  tags = {
    Name        = "Loki Storage"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# 配置 S3 存储桶版本控制
resource "aws_s3_bucket_versioning" "loki_storage" {
  bucket = aws_s3_bucket.loki_storage.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 配置 S3 存储桶加密
resource "aws_s3_bucket_server_side_encryption_configuration" "loki_storage" {
  bucket = aws_s3_bucket.loki_storage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 配置 S3 存储桶生命周期规则（可选，用于清理旧数据）
resource "aws_s3_bucket_lifecycle_configuration" "loki_storage" {
  bucket = aws_s3_bucket.loki_storage.id

  rule {
    id     = "delete-old-logs"
    status = "Enabled"

    expiration {
      days = var.loki_retention_days
    }
  }
}

# 创建 IAM 策略，允许访问 Loki S3 存储桶
resource "aws_iam_policy" "loki_s3_access" {
  name        = "${var.cluster_name}-loki-s3-access-policy"
  description = "Policy for Loki to access S3 storage bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.loki_storage.arn,
          "${aws_s3_bucket.loki_storage.arn}/*"
        ]
      }
    ]
  })

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# 获取 EKS 集群的 OIDC 提供商
data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_name
}

data "aws_iam_openid_connect_provider" "eks" {
  url = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

# 创建 IAM Role，用于 IRSA
resource "aws_iam_role" "loki_s3_role" {
  name = "${var.cluster_name}-loki-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = data.aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:monitoring:loki-s3-service-account"
            "${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# 将策略附加到角色
resource "aws_iam_role_policy_attachment" "loki_s3_access" {
  role       = aws_iam_role.loki_s3_role.name
  policy_arn = aws_iam_policy.loki_s3_access.arn
}

# 配置 Kubernetes Provider
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      module.eks.cluster_name
    ]
  }
}

# 创建 Kubernetes Namespace
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      name        = "monitoring"
      environment = var.environment
    }
  }
}

# 创建 Kubernetes ServiceAccount，关联 IAM Role
resource "kubernetes_service_account" "loki_s3" {
  depends_on = [module.eks]

  metadata {
    name      = "loki-s3-service-account"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.loki_s3_role.arn
    }
    labels = {
      app         = "loki"
      environment = var.environment
    }
  }
}

# 输出值
output "cluster_name" {
  description = "EKS 集群名称"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS 集群端点"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "EKS 集群 CA 证书"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "loki_s3_bucket_name" {
  description = "Loki S3 存储桶名称"
  value       = aws_s3_bucket.loki_storage.id
}

output "aws_region" {
  description = "AWS 区域"
  value       = var.aws_region
}

output "loki_s3_bucket_arn" {
  description = "Loki S3 存储桶 ARN"
  value       = aws_s3_bucket.loki_storage.arn
}

output "loki_iam_role_arn" {
  description = "Loki IRSA IAM Role ARN"
  value       = aws_iam_role.loki_s3_role.arn
}

output "loki_service_account_name" {
  description = "Loki ServiceAccount 名称"
  value       = kubernetes_service_account.loki_s3.metadata[0].name
}

output "configure_kubectl" {
  description = "配置 kubectl 的命令"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

