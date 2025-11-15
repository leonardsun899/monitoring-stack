# Terraform 配置 - EKS 集群和 Loki S3 设置

本 Terraform 配置用于自动创建：
- AWS EKS 集群
- VPC 和网络配置
- S3 存储桶（用于 Loki）
- IRSA（IAM Roles for Service Accounts）配置
- Kubernetes ServiceAccount

## 📋 前置条件

1. **安装 Terraform**
   ```bash
   # macOS
   brew install terraform
   
   # 或从 https://www.terraform.io/downloads 下载
   ```

2. **安装 AWS CLI 并配置凭证**
   ```bash
   aws configure
   ```

3. **确保有足够的 AWS 权限**
   - 创建 EKS 集群
   - 创建 VPC 和网络资源
   - 创建 S3 存储桶
   - 创建 IAM 角色和策略

## 🚀 快速开始

### 1. 配置变量

复制示例配置文件并修改：

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

编辑 `terraform.tfvars`，**重要**：修改 `loki_s3_bucket_name` 为全局唯一的名称：

```hcl
loki_s3_bucket_name = "your-org-loki-storage-us-west-2-12345"
```

### 2. 初始化 Terraform

```bash
terraform init
```

### 3. 预览变更

```bash
terraform plan
```

### 4. 应用配置

```bash
terraform apply
```

输入 `yes` 确认创建资源。

### 5. 配置 kubectl

Terraform 输出会显示配置 kubectl 的命令，或手动运行：

```bash
aws eks update-kubeconfig --name <cluster-name> --region <region>
```

或使用 Terraform 输出：

```bash
terraform output -raw configure_kubectl | bash
```

### 6. 验证部署

```bash
# 检查集群状态
kubectl cluster-info

# 检查节点
kubectl get nodes

# 检查 ServiceAccount
kubectl get serviceaccount -n monitoring loki-s3-service-account
```

## 📝 更新 Loki Values 文件

Terraform 部署完成后，需要更新 Loki values 文件以使用 Terraform 创建的资源。

### 方法 1：使用 Terraform 输出手动更新

获取 Terraform 输出值：

```bash
# 获取 S3 存储桶名称
terraform output loki_s3_bucket_name

# 获取 AWS 区域
terraform output aws_region
```

然后更新 `monitoring/values/loki-values-s3.yaml`：

**注意**：ServiceAccount 名称固定为 `loki-s3-service-account`，不需要从 Terraform 输出获取。

```yaml
loki:
  storage:
    bucketNames:
      chunks: <terraform-output-bucket-name>
      ruler: <terraform-output-bucket-name>
    s3:
      region: <aws-region>
      
serviceAccount:
  create: false
  name: loki-s3-service-account
```

### 方法 2：使用脚本自动更新（推荐）

创建并运行更新脚本：

```bash
# 创建更新脚本
cat > update-loki-values.sh << 'EOF'
#!/bin/bash
set -e

BUCKET_NAME=$(terraform -chdir=terraform output -raw loki_s3_bucket_name)
AWS_REGION=$(terraform -chdir=terraform output -raw aws_region 2>/dev/null || echo "us-west-2")

# 更新 loki-values-s3.yaml
sed -i.bak \
  -e "s|\${LOKI_S3_BUCKET_NAME}|${BUCKET_NAME}|g" \
  -e "s|\${AWS_REGION}|${AWS_REGION}|g" \
  monitoring/values/loki-values-s3.yaml

echo "✅ 已更新 monitoring/values/loki-values-s3.yaml"
echo "   S3 Bucket: ${BUCKET_NAME}"
echo "   AWS Region: ${AWS_REGION}"
EOF

chmod +x update-loki-values.sh
./update-loki-values.sh
```

## 🔧 配置说明

### 变量说明

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `aws_region` | AWS 区域 | `us-west-2` |
| `cluster_name` | EKS 集群名称 | `monitoring-stack-cluster` |
| `kubernetes_version` | Kubernetes 版本 | `1.28` |
| `node_min_size` | 节点组最小实例数 | `1` |
| `node_max_size` | 节点组最大实例数 | `3` |
| `node_desired_size` | 节点组期望实例数 | `2` |
| `node_instance_types` | 节点实例类型 | `["t3.medium"]` |
| `loki_s3_bucket_name` | Loki S3 存储桶名称（**必须全局唯一**） | 无默认值 |
| `loki_retention_days` | Loki 日志保留天数 | `30` |

### 创建的资源

1. **EKS 集群**
   - 启用 IRSA
   - 配置节点组
   - 自动创建 OIDC 提供商

2. **VPC 和网络**
   - VPC
   - 公有和私有子网
   - NAT 网关
   - 路由表

3. **S3 存储桶**
   - 用于 Loki 日志存储
   - 启用版本控制
   - 启用加密
   - 配置生命周期规则

4. **IAM 资源**
   - IAM 策略（S3 访问权限）
   - IAM Role（用于 IRSA）
   - 信任策略（关联到 ServiceAccount）

5. **Kubernetes 资源**
   - `monitoring` Namespace
   - `loki-s3-service-account` ServiceAccount（已配置 IRSA 注解）

## 🔍 验证 IRSA 配置

部署完成后，验证 IRSA 是否正常工作：

```bash
# 检查 ServiceAccount
kubectl describe serviceaccount -n monitoring loki-s3-service-account

# 应该看到注解：
# eks.amazonaws.com/role-arn: arn:aws:iam::<account-id>:role/<role-name>

# 检查 IAM Role
aws iam get-role --role-name <cluster-name>-loki-s3-role

# 检查策略
aws iam list-attached-role-policies --role-name <cluster-name>-loki-s3-role
```

## 🗑️ 清理资源

删除所有创建的资源：

```bash
terraform destroy
```

**注意**：这会删除所有资源，包括 EKS 集群、S3 存储桶等。确保已备份重要数据。

## 📚 参考

- [Terraform AWS EKS Module](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/)
- [Terraform AWS VPC Module](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/)
- [AWS EKS IRSA 文档](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)

