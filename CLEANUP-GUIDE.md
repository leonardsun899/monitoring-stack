# 资源清理指南

本指南说明如何安全地删除所有测试资源。

---

## 📋 清理步骤

### 方式 1: 使用 Terraform Destroy（推荐）

**大多数情况下，只需要运行 `terraform destroy` 即可删除所有资源。**

```bash
cd terraform
terraform destroy
```

**Terraform 会自动删除：**

- ✅ EKS 集群和节点组
- ✅ VPC、子网、NAT Gateway、Internet Gateway
- ✅ S3 存储桶（如果配置了 `force_destroy = true`）
- ✅ IAM 角色和策略
- ✅ LoadBalancer 服务（如果 `create_loadbalancer_services = true`）
- ✅ Kubernetes 命名空间和 ServiceAccount（如果 `create_kubernetes_resources = true`）

---

## ⚠️ 注意事项

### 1. 备份重要数据

在删除之前，请确保已备份重要数据：

```bash
# 备份 Grafana Dashboard（如果需要）
# 在 Grafana UI 中导出 Dashboard JSON

# 备份 Prometheus 数据（如果需要）
# Prometheus 数据存储在 PVC 中，destroy 后无法恢复

# 备份 Loki 日志（如果需要）
# Loki 日志存储在 S3 中，destroy 后无法恢复（除非已配置备份）
```

### 2. 删除顺序

**推荐顺序：**

1. **先删除 ArgoCD 应用**（可选，但推荐）

   ```bash
   # 删除 ArgoCD 应用，让它们自动清理 Kubernetes 资源
   kubectl delete application -n argocd --all

   # 等待应用删除完成
   kubectl get application -n argocd
   ```

2. **然后运行 terraform destroy**
   ```bash
   cd terraform
   terraform destroy
   ```

### 3. 可能遇到的问题

#### 问题 1: LoadBalancer 删除失败

**错误信息：**

```
Error: deleting EC2 Subnet (...) has dependencies and cannot be deleted
Error: deleting EC2 Internet Gateway (...) has some mapped public address(es)
```

**原因：** LoadBalancer 可能还在删除过程中，需要等待。

**解决方案：**

```bash
# 检查 LoadBalancer 状态
aws elbv2 describe-load-balancers --region ap-southeast-2

# 如果还有 LoadBalancer，等待它们删除完成（通常需要几分钟）
# 然后重新运行 terraform destroy
```

#### 问题 2: S3 Bucket 删除失败

**错误信息：**

```
Error: deleting S3 Bucket: BucketNotEmpty
```

**原因：** S3 bucket 中还有对象或版本。

**解决方案：**

```bash
# 检查 bucket 内容
aws s3 ls s3://<bucket-name> --recursive

# 如果配置了 force_destroy = true，Terraform 会自动删除
# 如果仍然失败，手动清空 bucket：
aws s3 rm s3://<bucket-name> --recursive
aws s3api delete-bucket --bucket <bucket-name> --region ap-southeast-2
```

#### 问题 3: NAT Gateway 删除失败

**错误信息：**

```
Error: deleting NAT Gateway: DependencyViolation
```

**原因：** NAT Gateway 可能还有关联的资源。

**解决方案：**

```bash
# 检查 NAT Gateway 状态
aws ec2 describe-nat-gateways --region ap-southeast-2

# 等待 NAT Gateway 状态变为 "deleted"
# 然后重新运行 terraform destroy
```

#### 问题 4: EKS 集群删除失败

**错误信息：**

```
Error: deleting EKS Cluster: ResourceInUseException
```

**原因：** 集群中可能还有资源未删除。

**解决方案：**

```bash
# 检查集群中的资源
kubectl get all --all-namespaces

# 删除所有资源（如果还有残留）
kubectl delete all --all --all-namespaces

# 等待资源删除完成，然后重新运行 terraform destroy
```

---

## 🔍 完整清理检查清单

### 步骤 1: 检查当前资源

```bash
# 检查 Terraform 管理的资源
cd terraform
terraform state list

# 检查 EKS 集群
aws eks list-clusters --region ap-southeast-2

# 检查 LoadBalancer
aws elbv2 describe-load-balancers --region ap-southeast-2

# 检查 S3 bucket
aws s3 ls | grep loki

# 检查 Kubernetes 资源
kubectl get all --all-namespaces
```

### 步骤 2: 删除 ArgoCD 应用（可选）

```bash
# 删除所有 ArgoCD 应用
kubectl delete application -n argocd --all

# 等待删除完成
kubectl get application -n argocd

# 检查 Kubernetes 资源是否已清理
kubectl get all --all-namespaces
```

### 步骤 3: 运行 Terraform Destroy

```bash
cd terraform

# 预览要删除的资源
terraform plan -destroy

# 确认无误后执行删除
terraform destroy

# 如果遇到错误，根据错误信息解决后重新运行
```

### 步骤 4: 验证资源已删除

```bash
# 检查 EKS 集群
aws eks list-clusters --region ap-southeast-2
# 应该返回空列表

# 检查 VPC
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*eks-test*" --region ap-southeast-2
# 应该返回空列表

# 检查 S3 bucket
aws s3 ls | grep loki
# 应该返回空

# 检查 LoadBalancer
aws elbv2 describe-load-balancers --region ap-southeast-2
# 应该返回空列表

# 检查 IAM 角色
aws iam list-roles --query 'Roles[?contains(RoleName, `eks-test`)].RoleName' --region ap-southeast-2
# 应该返回空列表
```

---

## 🚨 强制清理（如果 terraform destroy 失败）

如果 `terraform destroy` 失败且无法解决，可以尝试手动清理：

### 1. 手动删除 LoadBalancer

```bash
# 获取 LoadBalancer ARN
aws elbv2 describe-load-balancers --region ap-southeast-2 --query 'LoadBalancers[*].LoadBalancerArn' --output text

# 删除每个 LoadBalancer
aws elbv2 delete-load-balancer --load-balancer-arn <arn> --region ap-southeast-2
```

### 2. 手动删除 NAT Gateway

```bash
# 获取 NAT Gateway ID
aws ec2 describe-nat-gateways --region ap-southeast-2 --query 'NatGateways[*].NatGatewayId' --output text

# 删除每个 NAT Gateway
aws ec2 delete-nat-gateway --nat-gateway-id <id> --region ap-southeast-2
```

### 3. 手动删除 EIP

```bash
# 获取未关联的 EIP
aws ec2 describe-addresses --region ap-southeast-2 --query 'Addresses[?AssociationId==null].AllocationId' --output text

# 释放每个 EIP
aws ec2 release-address --allocation-id <id> --region ap-southeast-2
```

### 4. 手动清空并删除 S3 Bucket

```bash
# 获取 bucket 名称
cd terraform
BUCKET_NAME=$(terraform output -raw loki_s3_bucket_name 2>/dev/null || echo "")

# 如果 Terraform 已删除，从 AWS 直接查找
aws s3 ls | grep loki

# 清空 bucket
aws s3 rm s3://$BUCKET_NAME --recursive

# 删除所有版本
aws s3api delete-bucket --bucket $BUCKET_NAME --region ap-southeast-2
```

### 5. 重新运行 terraform destroy

手动清理后，重新运行：

```bash
cd terraform
terraform destroy
```

---

## 📝 清理后检查

清理完成后，验证所有资源已删除：

```bash
# 检查所有相关资源
echo "=== 检查 EKS 集群 ==="
aws eks list-clusters --region ap-southeast-2

echo "=== 检查 VPC ==="
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*eks-test*" --region ap-southeast-2

echo "=== 检查 S3 Bucket ==="
aws s3 ls | grep loki

echo "=== 检查 LoadBalancer ==="
aws elbv2 describe-load-balancers --region ap-southeast-2

echo "=== 检查 IAM 角色 ==="
aws iam list-roles --query 'Roles[?contains(RoleName, `eks-test`)].RoleName' --region ap-southeast-2

echo "=== 检查 IAM 策略 ==="
aws iam list-policies --query 'Policies[?contains(PolicyName, `eks-test`)].PolicyName' --region ap-southeast-2
```

所有检查应该返回空结果。

---

## 💡 最佳实践

### 1. 使用 Terraform Workspace

如果需要在多个环境之间切换，可以使用 Terraform Workspace：

```bash
# 创建新的 workspace
terraform workspace new test

# 切换到 workspace
terraform workspace select test

# 在特定 workspace 中 destroy
terraform destroy
```

### 2. 保留 Terraform State

如果需要保留 Terraform State 文件（用于后续重新创建），可以在 destroy 前备份：

```bash
# 备份 state 文件
cp terraform/terraform.tfstate terraform/terraform.tfstate.backup
```

### 3. 使用 Terraform Destroy 的选项

```bash
# 自动确认（非交互式）
terraform destroy -auto-approve

# 只删除特定资源
terraform destroy -target=aws_s3_bucket.loki_storage

# 显示详细输出
terraform destroy -verbose
```

---

## ⏱️ 预计清理时间

- **EKS 集群删除**: 5-10 分钟
- **LoadBalancer 删除**: 1-2 分钟
- **NAT Gateway 删除**: 2-5 分钟
- **S3 Bucket 删除**: 取决于数据量，通常 1-5 分钟
- **VPC 删除**: 1-2 分钟

**总预计时间**: 10-25 分钟

---

## 🔄 重新部署

如果清理后需要重新部署：

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

然后按照 [COMPLETE-MONITORING-STACK-SETUP.md](./COMPLETE-MONITORING-STACK-SETUP.md) 的步骤重新部署监控栈。

---

## 📚 参考

- [Terraform Destroy 文档](https://www.terraform.io/docs/cli/commands/destroy.html)
- [AWS EKS 删除指南](https://docs.aws.amazon.com/eks/latest/userguide/delete-cluster.html)
- [AWS VPC 删除指南](https://docs.aws.amazon.com/vpc/latest/userguide/delete-vpc.html)

---

## ❓ 常见问题

### Q: terraform destroy 会删除所有资源吗？

**A:** 是的，`terraform destroy` 会删除 Terraform state 中管理的所有资源。但是：

- 如果 `create_loadbalancer_services = false`，LoadBalancer 服务不会由 Terraform 管理，需要手动删除
- 如果 `create_kubernetes_resources = false`，Kubernetes 资源不会由 Terraform 管理，需要手动删除或通过 ArgoCD 删除

### Q: 删除后数据可以恢复吗？

**A:** 不可以。删除后所有数据都会丢失：

- Prometheus Metrics 数据（存储在 EBS 卷中）
- Loki 日志数据（存储在 S3 中）
- Grafana Dashboard 配置（存储在 EBS 卷中）

**建议**: 在删除前备份重要数据。

### Q: 删除过程中可以中断吗？

**A:** 不推荐。如果中断，可能导致资源处于不一致状态。如果必须中断：

1. 等待当前资源删除完成
2. 检查剩余资源
3. 手动清理或重新运行 `terraform destroy`

### Q: 如何只删除部分资源？

**A:** 使用 `-target` 选项：

```bash
# 只删除 S3 bucket
terraform destroy -target=aws_s3_bucket.loki_storage

# 只删除 EKS 集群
terraform destroy -target=module.eks
```

---

**需要帮助？** 查看 [DEBUG.md](./DEBUG.md) 获取故障排查指南。
