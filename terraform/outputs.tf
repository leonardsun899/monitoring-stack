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

# IAM Role ARN (for manually creating ServiceAccount with IRSA)
output "loki_s3_role_arn" {
  description = "IAM Role ARN for Loki S3 access (for ServiceAccount annotation)"
  value       = aws_iam_role.loki_s3_role.arn
}

# VPC ID (for cleanup scripts)
output "vpc_id" {
  description = "VPC ID (useful for cleanup scripts)"
  value       = module.vpc.vpc_id
}

# LoadBalancer DNS names for exposed services
# Note: These may be empty initially until LoadBalancers are provisioned (usually takes 1-2 minutes)
# If outputs are empty, wait a few minutes and run: terraform refresh && terraform output

# ArgoCD Server LoadBalancer DNS
output "argocd_server_lb_dns" {
  description = "ArgoCD Server LoadBalancer DNS name or IP"
  value = var.create_loadbalancer_services ? (
    try(
      kubernetes_service.argocd_server[0].status[0].load_balancer[0].ingress[0].hostname != "" ? kubernetes_service.argocd_server[0].status[0].load_balancer[0].ingress[0].hostname : kubernetes_service.argocd_server[0].status[0].load_balancer[0].ingress[0].ip,
      ""
    )
  ) : null
}

# ArgoCD Server LoadBalancer URL
output "argocd_server_url" {
  description = "ArgoCD Server URL (HTTP)"
  value = var.create_loadbalancer_services ? (
    try(
      kubernetes_service.argocd_server[0].status[0].load_balancer[0].ingress[0].hostname != "" ? "http://${kubernetes_service.argocd_server[0].status[0].load_balancer[0].ingress[0].hostname}" : "http://${kubernetes_service.argocd_server[0].status[0].load_balancer[0].ingress[0].ip}",
      ""
    )
  ) : null
}

# Grafana LoadBalancer DNS
output "grafana_lb_dns" {
  description = "Grafana LoadBalancer DNS name or IP"
  value = var.create_loadbalancer_services ? (
    try(
      kubernetes_service.grafana[0].status[0].load_balancer[0].ingress[0].hostname != "" ? kubernetes_service.grafana[0].status[0].load_balancer[0].ingress[0].hostname : kubernetes_service.grafana[0].status[0].load_balancer[0].ingress[0].ip,
      ""
    )
  ) : null
}

# Grafana LoadBalancer URL
output "grafana_url" {
  description = "Grafana URL"
  value = var.create_loadbalancer_services ? (
    try(
      kubernetes_service.grafana[0].status[0].load_balancer[0].ingress[0].hostname != "" ? "http://${kubernetes_service.grafana[0].status[0].load_balancer[0].ingress[0].hostname}" : "http://${kubernetes_service.grafana[0].status[0].load_balancer[0].ingress[0].ip}",
      ""
    )
  ) : null
}

# Nginx Test App LoadBalancer DNS
output "nginx_lb_dns" {
  description = "Nginx Test App LoadBalancer DNS name or IP"
  value = var.create_loadbalancer_services ? (
    try(
      kubernetes_service.nginx[0].status[0].load_balancer[0].ingress[0].hostname != "" ? kubernetes_service.nginx[0].status[0].load_balancer[0].ingress[0].hostname : kubernetes_service.nginx[0].status[0].load_balancer[0].ingress[0].ip,
      ""
    )
  ) : null
}

# Nginx Test App LoadBalancer URL
output "nginx_url" {
  description = "Nginx Test App URL"
  value = var.create_loadbalancer_services ? (
    try(
      kubernetes_service.nginx[0].status[0].load_balancer[0].ingress[0].hostname != "" ? "http://${kubernetes_service.nginx[0].status[0].load_balancer[0].ingress[0].hostname}" : "http://${kubernetes_service.nginx[0].status[0].load_balancer[0].ingress[0].ip}",
      ""
    )
  ) : null
}

# Summary output with all service URLs
output "service_urls" {
  description = "Summary of all exposed service URLs"
  value = {
    argocd = var.create_loadbalancer_services ? (
      try(
        kubernetes_service.argocd_server[0].status[0].load_balancer[0].ingress[0].hostname != "" ? "http://${kubernetes_service.argocd_server[0].status[0].load_balancer[0].ingress[0].hostname}" : "http://${kubernetes_service.argocd_server[0].status[0].load_balancer[0].ingress[0].ip}",
        "Pending..."
      )
    ) : "Not created (create_loadbalancer_services = false)"
    grafana = var.create_loadbalancer_services ? (
      try(
        kubernetes_service.grafana[0].status[0].load_balancer[0].ingress[0].hostname != "" ? "http://${kubernetes_service.grafana[0].status[0].load_balancer[0].ingress[0].hostname}" : "http://${kubernetes_service.grafana[0].status[0].load_balancer[0].ingress[0].ip}",
        "Pending..."
      )
    ) : "Not created (create_loadbalancer_services = false)"
    nginx = var.create_loadbalancer_services ? (
      try(
        kubernetes_service.nginx[0].status[0].load_balancer[0].ingress[0].hostname != "" ? "http://${kubernetes_service.nginx[0].status[0].load_balancer[0].ingress[0].hostname}" : "http://${kubernetes_service.nginx[0].status[0].load_balancer[0].ingress[0].ip}",
        "Pending..."
      )
    ) : "Not created (create_loadbalancer_services = false)"
  }
}

