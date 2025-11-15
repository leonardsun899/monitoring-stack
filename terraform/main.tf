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

# Configure AWS Provider
provider "aws" {
  region = var.aws_region
}

# Get current AWS account information
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Auto-generate bucket name if not specified
locals {
  loki_bucket_name = var.loki_s3_bucket_name != "" ? var.loki_s3_bucket_name : "${var.cluster_name}-loki-storage-${random_id.bucket_suffix.hex}"
}

# Random suffix to ensure bucket name uniqueness
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Create EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Enable IRSA
  enable_irsa = true

  # Node group configuration
  eks_managed_node_groups = {
    main = {
      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      # Node labels
      labels = {
        Environment = var.environment
      }
    }
  }

  # Cluster tags
  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Create VPC
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

# Create S3 bucket for Loki
resource "aws_s3_bucket" "loki_storage" {
  bucket = local.loki_bucket_name

  # Allow deletion of non-empty bucket during destroy
  # Note: This will force delete all objects and versions in the bucket
  force_destroy = true

  tags = {
    Name        = "Loki Storage"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Configure S3 bucket versioning
resource "aws_s3_bucket_versioning" "loki_storage" {
  bucket = aws_s3_bucket.loki_storage.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Configure S3 bucket public access block (security best practice)
resource "aws_s3_bucket_public_access_block" "loki_storage" {
  bucket = aws_s3_bucket.loki_storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Configure S3 bucket encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "loki_storage" {
  bucket = aws_s3_bucket.loki_storage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Configure S3 bucket lifecycle rules (for cleaning up old data and versions)
resource "aws_s3_bucket_lifecycle_configuration" "loki_storage" {
  bucket = aws_s3_bucket.loki_storage.id

  rule {
    id     = "delete-old-logs"
    status = "Enabled"

    # Delete expired objects
    expiration {
      days = var.loki_retention_days
    }

    # Delete old versions (helps with bucket deletion during destroy)
    noncurrent_version_expiration {
      noncurrent_days = var.loki_retention_days
    }
  }
}

# Create IAM policy to allow access to Loki S3 bucket
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

# Get EKS cluster OIDC provider
data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_name
}

data "aws_iam_openid_connect_provider" "eks" {
  url = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

# Create IAM Role for IRSA
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

# Attach policy to role
resource "aws_iam_role_policy_attachment" "loki_s3_access" {
  role       = aws_iam_role.loki_s3_role.name
  policy_arn = aws_iam_policy.loki_s3_access.arn
}

# Configure Kubernetes Provider
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

# Create Kubernetes Namespace
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      name        = "monitoring"
      environment = var.environment
    }
  }
}

# Create Kubernetes ServiceAccount with IAM Role association
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
