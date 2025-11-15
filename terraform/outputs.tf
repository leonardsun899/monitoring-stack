# Output values - only essential outputs

# Command to configure kubectl (for connecting to cluster)
output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

# Loki S3 bucket name (for updating loki-values-s3.yaml)
output "loki_s3_bucket_name" {
  description = "Loki S3 bucket name"
  value       = aws_s3_bucket.loki_storage.id
}

# AWS region (for updating loki-values-s3.yaml)
output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

