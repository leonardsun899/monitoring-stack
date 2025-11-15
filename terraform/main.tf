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
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
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

  # Cluster endpoint access configuration
  # Allow public access for kubectl from local machine
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # Optional: Restrict public access to specific CIDR blocks for security
  # cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]  # Allow from anywhere (default)

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

    # Apply to all objects in the bucket
    filter {
      prefix = "" # Empty prefix means all objects
    }

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

# Create IAM Role for IRSA
# Use EKS module outputs directly instead of data sources
# The EKS module automatically creates OIDC provider when enable_irsa = true
resource "aws_iam_role" "loki_s3_role" {
  depends_on = [module.eks]

  name = "${var.cluster_name}-loki-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:monitoring:loki-s3-service-account"
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
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

# Create IAM Role for EBS CSI Driver (IRSA)
resource "aws_iam_role" "ebs_csi_driver" {
  name = "${var.cluster_name}-ebs-csi-driver-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
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

# Attach AWS managed policy for EBS CSI Driver
resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Install EBS CSI Driver as EKS Add-on
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = "v1.32.0-eksbuild.1" # Use latest compatible version
  service_account_role_arn    = aws_iam_role.ebs_csi_driver.arn
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.ebs_csi_driver
  ]

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Wait for EKS cluster to be fully ready
# This ensures the cluster API server is accessible before creating Kubernetes resources
# Note: If timeout issues persist, set create_kubernetes_resources = false and create resources manually
resource "time_sleep" "wait_for_cluster" {
  count = (var.create_kubernetes_resources || var.create_loadbalancer_services) ? 1 : 0

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups
  ]

  create_duration = "90s" # Wait 90 seconds for cluster to be fully ready
}

# Configure Kubernetes Provider
# Note: The provider configuration uses module outputs, which ensures EKS cluster is created first
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

# Create Kubernetes Namespace (optional)
# Wait for EKS cluster to be fully ready before creating namespace
# Can be disabled if you want to create namespace manually or let ArgoCD create it
# Recommended: Set create_kubernetes_resources = false to avoid timeout issues
resource "kubernetes_namespace" "monitoring" {
  count = var.create_kubernetes_resources ? 1 : 0

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    time_sleep.wait_for_cluster[0]
  ]

  metadata {
    name = "monitoring"
    labels = {
      name        = "monitoring"
      environment = var.environment
    }
  }
}

# Create Kubernetes ServiceAccount with IAM Role association (optional)
# Can be disabled if you want to create ServiceAccount manually or via ArgoCD
# Recommended: Set create_kubernetes_resources = false to avoid timeout issues
resource "kubernetes_service_account" "loki_s3" {
  count = var.create_kubernetes_resources ? 1 : 0

  depends_on = [
    module.eks,
    time_sleep.wait_for_cluster[0]
  ]

  metadata {
    name      = "loki-s3-service-account"
    namespace = var.create_kubernetes_resources ? kubernetes_namespace.monitoring[0].metadata[0].name : "monitoring"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.loki_s3_role.arn
    }
    labels = {
      app         = "loki"
      environment = var.environment
    }
  }
}

# Create gp3 StorageClass for EBS volumes
# EKS cluster comes with gp2 by default, but we need gp3 for better performance and cost
# This is a cluster-level resource, so it's always created (not dependent on create_kubernetes_resources)
resource "kubernetes_storage_class" "gp3" {
  depends_on = [
    module.eks
  ]

  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type   = "gp3"
    fsType = "ext4"
  }
}

# Create LoadBalancer services in Terraform to ensure they are deleted during destroy
# This prevents dependency issues when destroying VPC resources

# Create namespaces for LoadBalancer services (if they don't exist)
resource "kubernetes_namespace" "argocd" {
  count = var.create_loadbalancer_services ? 1 : 0

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    time_sleep.wait_for_cluster[0]
  ]

  metadata {
    name = "argocd"
    labels = {
      name        = "argocd"
      environment = var.environment
    }
  }
}

resource "kubernetes_namespace" "test_app" {
  count = var.create_loadbalancer_services ? 1 : 0

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    time_sleep.wait_for_cluster[0]
  ]

  metadata {
    name = "test-app"
    labels = {
      name        = "test-app"
      environment = var.environment
    }
  }
}

# Ensure monitoring namespace exists for LoadBalancer services
# Use existing monitoring namespace if create_kubernetes_resources is true,
# otherwise create a new one for LoadBalancer services
resource "kubernetes_namespace" "monitoring_for_lb" {
  count = var.create_loadbalancer_services && !var.create_kubernetes_resources ? 1 : 0

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    time_sleep.wait_for_cluster[0]
  ]

  metadata {
    name = "monitoring"
    labels = {
      name        = "monitoring"
      environment = var.environment
    }
  }
}

# ArgoCD Server LoadBalancer Service
resource "kubernetes_service" "argocd_server" {
  count = var.create_loadbalancer_services ? 1 : 0

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    kubernetes_namespace.argocd[0]
  ]

  metadata {
    name      = "argocd-server"
    namespace = kubernetes_namespace.argocd[0].metadata[0].name
    labels = {
      "app.kubernetes.io/component" = "server"
      "app.kubernetes.io/name"      = "argocd-server"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  spec {
    type = "LoadBalancer"
    selector = {
      "app.kubernetes.io/name" = "argocd-server"
    }
    port {
      name        = "http"
      port        = 80
      protocol    = "TCP"
      target_port = 8080
    }
    port {
      name        = "https"
      port        = 443
      protocol    = "TCP"
      target_port = 8080
    }
  }
}

# Grafana LoadBalancer Service
resource "kubernetes_service" "grafana" {
  count = var.create_loadbalancer_services ? 1 : 0

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    kubernetes_namespace.monitoring,
    kubernetes_namespace.monitoring_for_lb
  ]

  metadata {
    name      = "prometheus-grafana"
    namespace = try(kubernetes_namespace.monitoring[0].metadata[0].name, kubernetes_namespace.monitoring_for_lb[0].metadata[0].name, "monitoring")
    labels = {
      "app.kubernetes.io/name" = "grafana"
    }
  }

  spec {
    type = "LoadBalancer"
    selector = {
      "app.kubernetes.io/name" = "grafana"
    }
    port {
      port        = 80
      protocol    = "TCP"
      target_port = 3000
    }
  }
}

# Nginx Test App LoadBalancer Service
resource "kubernetes_service" "nginx" {
  count = var.create_loadbalancer_services ? 1 : 0

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    kubernetes_namespace.test_app[0]
  ]

  metadata {
    name      = "nginx-test-app"
    namespace = kubernetes_namespace.test_app[0].metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "nginx"
    }
  }

  spec {
    type = "LoadBalancer"
    selector = {
      "app.kubernetes.io/name" = "nginx"
    }
    port {
      port        = 80
      protocol    = "TCP"
      target_port = 8080
    }
  }
}
