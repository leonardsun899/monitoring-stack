# 部署前检查清单

本文档列出了重新部署监控栈前需要检查的所有配置项。

## ✅ Terraform 配置检查

### 1. StorageClass 配置

- [x] `terraform/main.tf` 包含 `kubernetes_storage_class.gp3` 资源
- [x] StorageClass 使用 `ebs.csi.aws.com` provisioner
- [x] StorageClass 参数设置为 `type: gp3`

**文件位置**: `terraform/main.tf` (lines 329-352)

### 2. EKS 集群配置

- [x] 集群端点访问配置：`cluster_endpoint_public_access = true`
- [x] IRSA 已启用：`enable_irsa = true`
- [x] 节点组配置正确

**文件位置**: `terraform/main.tf` (lines 44-88)

### 3. S3 和 IRSA 配置

- [x] S3 bucket 配置（自动生成唯一名称）
- [x] IAM Role 和 Policy 配置
- [x] ServiceAccount 配置（可选，默认手动创建）

**文件位置**: `terraform/main.tf` (lines 105-327)

### 4. 变量配置

- [x] `create_kubernetes_resources` 默认值为 `false`（避免超时）
- [x] 所有必需变量都有默认值

**文件位置**: `terraform/variables.tf`

## ✅ ArgoCD Application 配置检查

### 1. Loki Application

- [x] Chart: `loki` version `6.0.0`
- [x] Values 文件: `monitoring/values/loki-values-s3.yaml`
- [x] Namespace: `monitoring`
- [x] Git 仓库配置正确

**文件位置**: `monitoring/argocd/loki.yaml`

### 2. Promtail Application

- [x] Chart: `promtail` version `6.0.0`
- [x] Values 文件: `monitoring/values/promtail-values.yaml`
- [x] Namespace: `monitoring`
- [x] Loki URL 配置正确: `http://loki.monitoring.svc:3100/loki/api/v1/push`

**文件位置**: `monitoring/argocd/promtail.yaml`

### 3. Prometheus Application

- [x] Chart: `kube-prometheus-stack` version `60.0.0`
- [x] Values 文件: `monitoring/values/prometheus-values.yaml`
- [x] Namespace: `monitoring`

**文件位置**: `monitoring/argocd/prometheus.yaml`

### 4. Nginx Test App

- [x] Chart: `nginx` version `22.3.2`
- [x] Values 文件: `test-app/values/nginx-values.yaml`
- [x] Namespace: `test-app`
- [x] ServiceMonitor 配置正确

**文件位置**: `test-app/argocd/nginx-app.yaml`

## ✅ Values 文件配置检查

### 1. Loki Values (`monitoring/values/loki-values-s3.yaml`)

- [x] `deploymentMode: SimpleScalable`
- [x] `schemaConfig` 已配置（必需）
- [x] S3 配置正确（bucket names, region）
- [x] `persistence.storageClassName: gp3`
- [x] `simpleScalable.backend.persistence.storageClassName: gp3`
- [x] `simpleScalable.write.persistence.storageClassName: gp3`
- [x] `serviceAccount.create: false`（使用 Terraform 创建的）
- [x] `serviceAccount.name: loki-s3-service-account`

**注意**: S3 bucket name 和 region 需要从 Terraform 输出更新

### 2. Promtail Values (`monitoring/values/promtail-values.yaml`)

- [x] Loki URL 配置: `http://loki.monitoring.svc:3100/loki/api/v1/push`
- [x] 使用默认配置（最小化覆盖）

### 3. Prometheus Values (`monitoring/values/prometheus-values.yaml`)

- [x] Prometheus `storageClassName: gp3`
- [x] Grafana `storageClassName: gp3`
- [x] Grafana `service.type: LoadBalancer`
- [x] Grafana datasources 配置（Prometheus 和 Loki）
- [x] Grafana `isDefault: false` 对于 Loki datasource

### 4. Nginx Values (`test-app/values/nginx-values.yaml`)

- [x] `service.type: LoadBalancer`
- [x] `metrics.enabled: true`
- [x] `metrics.serviceMonitor.enabled: true`

## ✅ 部署顺序

1. **Terraform 部署**

   ```bash
   cd terraform
   terraform init
   terraform plan
   terraform apply
   ```

2. **配置 kubectl**

   ```bash
   terraform output -raw configure_kubectl | bash
   ```

3. **更新 Loki Values 文件**

   ```bash
   cd ..
   ./terraform/update-loki-values.sh
   ```

   或手动更新 `monitoring/values/loki-values-s3.yaml` 中的：

   - `bucketNames.chunks` 和 `bucketNames.ruler`
   - `s3.region`

4. **创建 Namespace 和 ServiceAccount**

   ```bash
   # 方式 1: 手动创建
   kubectl create namespace monitoring
   ROLE_ARN=$(cd terraform && terraform output -raw loki_s3_role_arn)
   kubectl create serviceaccount loki-s3-service-account -n monitoring
   kubectl annotate serviceaccount loki-s3-service-account -n monitoring \
     eks.amazonaws.com/role-arn=${ROLE_ARN}

   # 方式 2: 让 ArgoCD 自动创建 namespace（推荐）
   # 只需要手动创建 ServiceAccount
   ```

5. **安装 ArgoCD**

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```

6. **配置 ArgoCD LoadBalancer**（可选）

   ```bash
   kubectl apply -f argocd/argocd-server-service.yaml
   ```

7. **部署应用**（按顺序）

   ```bash
   # 1. Loki
   kubectl apply -f monitoring/argocd/loki.yaml
   kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=loki -n monitoring --timeout=300s

   # 2. Promtail
   kubectl apply -f monitoring/argocd/promtail.yaml

   # 3. Prometheus
   kubectl apply -f monitoring/argocd/prometheus.yaml

   # 4. Nginx (可选)
   kubectl apply -f test-app/argocd/nginx-app.yaml
   ```

## ⚠️ 已知问题和解决方案

### 1. Loki PVC StorageClass 问题

**问题**: StatefulSet 的 `volumeClaimTemplates` 可能没有正确应用 `storageClassName`

**解决方案**:

- 已更新 values 文件添加组件级别的 persistence 配置
- 如果问题持续，使用临时修复：
  ```bash
  kubectl get pvc -n monitoring -l app.kubernetes.io/name=loki -o name | \
    xargs -I {} kubectl patch {} -n monitoring --type='merge' \
    -p '{"spec":{"storageClassName":"gp3"}}'
  ```

**参考文档**: `LOKI-PVC-TROUBLESHOOTING.md`

### 2. Terraform 超时问题

**问题**: 创建 Kubernetes 资源时可能超时

**解决方案**:

- 默认 `create_kubernetes_resources = false`
- 手动创建 namespace 和 ServiceAccount
- 或增加 `time_sleep` 等待时间

### 3. EKS 端点访问问题

**问题**: kubectl 无法连接集群

**解决方案**:

- Terraform 已配置 `cluster_endpoint_public_access = true`
- 如果仍有问题，检查 Security Group 规则

## 📋 验证清单

部署完成后，验证以下内容：

- [ ] StorageClass `gp3` 存在
- [ ] Namespace `monitoring` 和 `test-app` 存在
- [ ] ServiceAccount `loki-s3-service-account` 存在且配置了 IRSA
- [ ] 所有 ArgoCD Applications 状态为 `Synced` 和 `Healthy`
- [ ] Loki Pods 运行正常
- [ ] Promtail Pods 运行正常
- [ ] Prometheus Pods 运行正常
- [ ] Grafana 可以访问（LoadBalancer 或 port-forward）
- [ ] Nginx 测试应用可以访问（LoadBalancer）

## 🔍 快速验证命令

```bash
# 检查 StorageClass
kubectl get storageclass

# 检查所有应用状态
kubectl get applications -n argocd

# 检查 Pods
kubectl get pods -n monitoring
kubectl get pods -n test-app

# 检查 PVC
kubectl get pvc -n monitoring

# 检查 Services
kubectl get svc -n monitoring
kubectl get svc -n test-app

# 检查 ArgoCD
kubectl get svc -n argocd argocd-server
```

## 📝 配置文件位置总结

```
monitoring-satck/
├── terraform/
│   ├── main.tf                    # Terraform 主配置（包含 StorageClass）
│   ├── variables.tf                # 变量定义
│   ├── outputs.tf                 # 输出定义
│   └── terraform.tfvars.example   # 变量示例
├── monitoring/
│   ├── argocd/
│   │   ├── loki.yaml              # Loki ArgoCD Application
│   │   ├── promtail.yaml          # Promtail ArgoCD Application
│   │   └── prometheus.yaml        # Prometheus ArgoCD Application
│   └── values/
│       ├── loki-values-s3.yaml    # Loki Helm values
│       ├── promtail-values.yaml    # Promtail Helm values
│       └── prometheus-values.yaml  # Prometheus Helm values
├── test-app/
│   ├── argocd/
│   │   └── nginx-app.yaml         # Nginx ArgoCD Application
│   └── values/
│       └── nginx-values.yaml       # Nginx Helm values
└── argocd/
    └── argocd-server-service.yaml  # ArgoCD LoadBalancer Service
```

## 🚀 快速部署命令

```bash
# 1. Terraform
cd terraform && terraform apply

# 2. 配置 kubectl
terraform output -raw configure_kubectl | bash

# 3. 更新 Loki values
cd .. && ./terraform/update-loki-values.sh

# 4. 创建 ServiceAccount
ROLE_ARN=$(cd terraform && terraform output -raw loki_s3_role_arn)
kubectl create serviceaccount loki-s3-service-account -n monitoring
kubectl annotate serviceaccount loki-s3-service-account -n monitoring \
  eks.amazonaws.com/role-arn=${ROLE_ARN}

# 5. 安装 ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f argocd/argocd-server-service.yaml

# 6. 部署应用
kubectl apply -f monitoring/argocd/loki.yaml
kubectl apply -f monitoring/argocd/promtail.yaml
kubectl apply -f monitoring/argocd/prometheus.yaml
kubectl apply -f test-app/argocd/nginx-app.yaml
```
