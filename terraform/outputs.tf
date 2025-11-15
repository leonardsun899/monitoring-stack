# 输出值 - 仅保留必要的输出

# 配置 kubectl 的命令（用于连接集群）
output "configure_kubectl" {
  description = "配置 kubectl 的命令"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

# Loki S3 存储桶名称（用于更新 loki-values-s3.yaml）
output "loki_s3_bucket_name" {
  description = "Loki S3 存储桶名称"
  value       = aws_s3_bucket.loki_storage.id
}

# AWS 区域（用于更新 loki-values-s3.yaml）
output "aws_region" {
  description = "AWS 区域"
  value       = var.aws_region
}

