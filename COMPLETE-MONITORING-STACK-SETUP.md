# 完整监控栈从零安装指南

## 🎯 目标

从零开始创建完整的监控栈，包括：

1. 使用 Terraform 创建 AWS EKS 集群、S3 存储桶和 IRSA 配置
2. 安装 ArgoCD
3. 部署测试应用（Nginx + Prometheus Exporter）
4. 部署监控栈（Prometheus + Grafana + Loki + Promtail）
5. 配置 Metrics 收集和 Grafana 报表

## 📋 前置条件

- AWS 账户和 AWS CLI 已配置
- Terraform >= 1.0 已安装
- `kubectl` 已安装
- Git 仓库（用于存储配置）
- 足够的 AWS 权限（创建 EKS、VPC、S3、IAM 资源）

### 检查存储类

在开始之前，请检查集群的存储类：

```bash
kubectl get storageclass
```

常见存储类名称：

- **AWS EKS**: `gp3`（推荐）, `gp2`
- DigitalOcean: `do-block-storage`
- GKE: `standard`, `premium-rwo`
- 其他: 查看上述命令的输出

**重要：**

- 本指南使用 Terraform 自动创建 AWS EKS 集群和相关资源
- 所有配置文件中的 `storageClassName` 已设置为 `gp3`
- **Loki 使用 S3 存储**：Terraform 会自动创建 S3 存储桶并配置 IRSA
- **使用 IRSA**：Terraform 会自动配置 IAM Roles for Service Accounts (IRSA)，无需在 Kubernetes 中存储访问密钥

---

## 🚀 Step 0: 使用 Terraform 创建 EKS 集群和基础设施

本步骤使用 Terraform 自动创建：

- AWS EKS 集群（启用 IRSA）
- VPC 和网络资源
- S3 存储桶（用于 Loki）
- IAM 策略和角色（IRSA）
- Kubernetes ServiceAccount（已配置 IRSA 注解）

### 0.1 配置 Terraform 变量

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

编辑 `terraform/terraform.tfvars`，根据你的需求修改配置：

```hcl
# AWS 配置
aws_region = "us-west-2"

# EKS 集群配置
cluster_name      = "monitoring-stack-cluster"
kubernetes_version = "1.28"
environment       = "production"

# Loki S3 配置
# 如果为空，Terraform 会自动生成唯一名称
loki_s3_bucket_name = ""  # 留空以自动生成，或指定一个全局唯一的名称
loki_retention_days = 30

# Kubernetes 资源创建（推荐：false，避免超时问题）
create_kubernetes_resources = false  # 设置为 false，手动创建 namespace 和 ServiceAccount
```

**重要说明**：

- 如果 `loki_s3_bucket_name` 为空，Terraform 会自动生成一个唯一名称
- **`create_kubernetes_resources = false`（推荐）**：Terraform 不会创建 Kubernetes namespace 和 ServiceAccount，需要手动创建（见 Step 0.8）
- 如果设置为 `true`，Terraform 会尝试创建，但可能遇到超时问题

### 0.2 初始化 Terraform

```bash
terraform init
```

这会下载所需的 Terraform providers 和 modules。

### 0.3 预览变更

```bash
terraform plan
```

检查将要创建的资源，确保配置正确。

### 0.4 应用配置

```bash
terraform apply
```

输入 `yes` 确认创建资源。这可能需要 15-20 分钟，因为需要创建 EKS 集群。

### 0.5 配置 kubectl

Terraform 完成后，配置 kubectl 连接到新创建的集群：

```bash
# 使用 Terraform 输出获取配置命令
terraform output -raw configure_kubectl | bash

# 或手动运行
aws eks update-kubeconfig --name <cluster-name> --region <region>
```

验证连接：

```bash
kubectl cluster-info
kubectl get nodes
```

**如果遇到连接超时问题**：

如果 `kubectl cluster-info` 报错 `i/o timeout`，可能是 EKS 集群端点访问配置问题：

1. **检查集群端点访问配置**：

   ```bash
   aws eks describe-cluster --name <cluster-name> --region <region> \
     --query 'cluster.resourcesVpcConfig.endpointPublicAccess'
   ```

2. **如果返回 `false`**，需要更新 Terraform 配置并重新应用：

   - Terraform 配置已包含 `cluster_endpoint_public_access = true`
   - 运行 `terraform apply` 更新集群配置
   - 等待几分钟让配置生效

3. **或者手动启用公共访问**（临时方案）：
   ```bash
   aws eks update-cluster-config \
     --name <cluster-name> \
     --region <region> \
     --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true
   ```
   然后等待几分钟，再尝试 `kubectl cluster-info`

### 0.6 更新 Loki Values 文件

Terraform 会自动创建 S3 存储桶和 ServiceAccount，现在需要更新 Loki values 文件以使用这些资源：

```bash
# 从项目根目录运行
cd ..
./terraform/update-loki-values.sh
```

这个脚本会：

- 从 Terraform 输出获取 S3 存储桶名称和 AWS 区域
- 自动更新 `monitoring/values/loki-values-s3.yaml` 文件
- 备份原文件

**手动方式**（如果脚本不可用）：

```bash
# 获取 Terraform 输出值
BUCKET_NAME=$(terraform -chdir=terraform output -raw loki_s3_bucket_name)
AWS_REGION=$(terraform -chdir=terraform output -raw aws_region)

# 更新 loki-values-s3.yaml
sed -i.bak \
  -e "s|\${LOKI_S3_BUCKET_NAME}|${BUCKET_NAME}|g" \
  -e "s|\${AWS_REGION}|${AWS_REGION}|g" \
  monitoring/values/loki-values-s3.yaml
```

### 0.7 验证 Terraform 创建的资源

```bash
# 检查 ServiceAccount（如果 create_kubernetes_resources = true）
kubectl get serviceaccount -n monitoring loki-s3-service-account -o yaml

# 应该看到注解：
# eks.amazonaws.com/role-arn: arn:aws:iam::<account-id>:role/<role-name>

# 检查 S3 存储桶名称
terraform -chdir=terraform output loki_s3_bucket_name

# 检查 AWS 区域
terraform -chdir=terraform output aws_region

# 检查 IAM Role ARN（用于手动创建 ServiceAccount）
terraform -chdir=terraform output loki_s3_role_arn
```

**Terraform 输出值：**

```bash
# 查看所有输出
cd terraform
terraform output

# 主要输出（用于配置 Loki）
terraform output configure_kubectl      # 配置 kubectl 的命令
terraform output loki_s3_bucket_name    # S3 存储桶名称
terraform output aws_region             # AWS 区域
terraform output loki_s3_role_arn       # IAM Role ARN（用于手动创建 ServiceAccount）
```

### 0.8 创建 Namespace 和 ServiceAccount（必需）

**默认情况下**，Terraform 不会创建 Kubernetes namespace 和 ServiceAccount（`create_kubernetes_resources = false`），需要手动创建：

**方式 1：手动创建 namespace 和 ServiceAccount（推荐）**

```bash
# 1. 创建 namespace
kubectl create namespace monitoring

# 2. 获取 IAM Role ARN
cd terraform
ROLE_ARN=$(terraform output -raw loki_s3_role_arn)

# 3. 创建 ServiceAccount（带 IRSA 注解）
kubectl create serviceaccount loki-s3-service-account -n monitoring
kubectl annotate serviceaccount loki-s3-service-account -n monitoring \
  eks.amazonaws.com/role-arn=${ROLE_ARN}

# 4. 验证
kubectl get serviceaccount -n monitoring loki-s3-service-account -o yaml
```

**方式 2：让 ArgoCD 自动创建 Namespace（更简单）**

ArgoCD Application 已配置 `CreateNamespace=true`，会自动创建 namespace。你只需要手动创建 ServiceAccount：

```bash
# 1. 配置 kubectl（如果还没有配置）
cd terraform
terraform output -raw configure_kubectl | bash

# 2. 获取 IAM Role ARN
ROLE_ARN=$(terraform output -raw loki_s3_role_arn)

# 3. 创建 ServiceAccount（ArgoCD 会在部署应用时自动创建 namespace）
kubectl create serviceaccount loki-s3-service-account -n monitoring
kubectl annotate serviceaccount loki-s3-service-account -n monitoring \
  eks.amazonaws.com/role-arn=${ROLE_ARN}

# 4. 验证
kubectl get serviceaccount -n monitoring loki-s3-service-account -o yaml
```

**注意**：

- **默认情况下**，Terraform **不会**创建 Kubernetes 资源（`create_kubernetes_resources = false`），避免超时问题
- 推荐使用**方式 2**：让 ArgoCD 自动创建 namespace，只手动创建 ServiceAccount
- 如果希望 Terraform 自动创建，可以设置 `create_kubernetes_resources = true`，但可能遇到超时问题

---

## 🚀 Step 1: 安装 ArgoCD

### 1.1 安装 ArgoCD

```bash
# 创建 argocd namespace
kubectl create namespace argocd

# 安装 ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 等待 ArgoCD 就绪
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
kubectl wait --for=condition=available --timeout=300s deployment/argocd-repo-server -n argocd
kubectl wait --for=condition=available --timeout=300s deployment/argocd-applicationset-controller -n argocd
```

### 1.2 获取 ArgoCD Admin 密码

```bash
# 获取初始 admin 密码
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

### 1.3 配置 ArgoCD Server 为 LoadBalancer（可选）

默认情况下，ArgoCD Server 使用 ClusterIP 类型，只能通过 port-forward 访问。如果需要外部访问，可以将其改为 LoadBalancer：

**方式 1: 使用配置文件（推荐，持久化）**

```bash
# 应用 Service 配置
kubectl apply -f argocd/argocd-server-service.yaml

# 等待 LoadBalancer 分配 IP
kubectl get svc -n argocd argocd-server -w

# 获取 LoadBalancer 地址
kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' && echo
```

**方式 2: 使用 kubectl patch（临时）**

```bash
# 临时修改为 LoadBalancer
kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"LoadBalancer"}}'
```

**注意**: 使用配置文件的方式更好，因为配置保存在 Git 仓库中，可以版本控制和重复使用。

### 1.4 访问 ArgoCD UI

**方式 1: 使用 LoadBalancer（如果已配置）**

```bash
# 获取 LoadBalancer 地址
kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' && echo

# 在浏览器中访问
# HTTP: http://<loadbalancer-ip>
# HTTPS: https://<loadbalancer-ip>
```

**方式 2: 使用 port-forward（默认方式）**

```bash
# 使用 port-forward 访问 ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# 访问 https://localhost:8080 (用户名: admin)
```

### 1.5 配置 ArgoCD CLI（可选）

```bash
# 安装 ArgoCD CLI
brew install argocd  # macOS
# 或从 https://argo-cd.readthedocs.io/en/stable/cli_installation/ 下载

# 登录
argocd login localhost:8080 --insecure
```

---

## 🚀 Step 2: 安装测试应用（Nginx + Prometheus Exporter）

### 2.1 创建测试应用目录结构

```bash
mkdir -p test-app/{argocd,values}
cd test-app
```

### 2.2 创建 ArgoCD Application

**`test-app/argocd/nginx-app.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nginx-test-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources: # 注意：使用 sources（复数）以支持多个仓库源
    - repoURL: https://charts.bitnami.com/bitnami
      chart: nginx
      targetRevision: 15.0.0
      helm:
        valueFiles:
          - $values/test-app/values/nginx-values.yaml
    - repoURL: https://github.com/leonardsun899/monitoring-stack.git # 替换为你的 Git 仓库地址
      targetRevision: main
      ref: values # 标识这个 source 用于提供 values 文件
  destination:
    server: https://kubernetes.default.svc
    namespace: test-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**注意：**

- 必须使用 `sources`（复数）而不是 `source`，因为需要同时引用 Helm Chart 仓库和 Git 仓库
- 第一个 source 是 Helm Chart 仓库
- 第二个 source 是 Git 仓库，用于提供 values 文件
- `ref: values` 告诉 ArgoCD 这个 source 用于 values 文件

### 2.3 创建 Values 文件（包含 Metrics Exporter）

**`test-app/values/nginx-values.yaml`**

```yaml
# Nginx 测试应用配置
# 尽量使用 Helm Chart 默认配置，只覆盖必要的设置

# 服务类型：LoadBalancer（用于外部访问）
service:
  type: LoadBalancer

# 启用 Prometheus Metrics Exporter（用于监控）
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
    namespace: monitoring
    labels:
      release: prometheus
```

**说明：**

- 尽量使用 Helm Chart 默认配置
- 只覆盖必要的设置（LoadBalancer 服务类型和 Metrics Exporter）
- 其他配置（如副本数、资源限制等）使用默认值

**注意：** 如果使用 Git 仓库，需要将 values 文件提交到仓库。如果直接使用，可以修改 Application 配置。

### 2.4 部署测试应用

**方式 A：使用 Git 仓库（推荐）**

```bash
# 提交到 Git 仓库
git add test-app/
git commit -m "Add nginx test app with metrics"
git push origin main

# 部署 ArgoCD Application
kubectl apply -f test-app/argocd/nginx-app.yaml
```

**方式 B：直接使用（临时测试）**

修改 `nginx-app.yaml`，移除 `ref: values`，直接使用本地 values：

```yaml
spec:
  source:
    repoURL: https://charts.bitnami.com/bitnami
    chart: nginx
    targetRevision: 15.0.0
    helm:
      values: |
        replicaCount: 2
        service:
          type: LoadBalancer
        metrics:
          enabled: true
          serviceMonitor:
            enabled: true
            namespace: monitoring
            labels:
              release: prometheus
```

### 2.5 验证测试应用

```bash
# 检查 Pod
kubectl get pods -n test-app

# 检查 Service
kubectl get svc -n test-app

# 获取 LoadBalancer 地址
kubectl get svc -n test-app nginx-test-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# 检查 Metrics Exporter
kubectl get svc -n test-app nginx-test-app-metrics
kubectl port-forward -n test-app svc/nginx-test-app-metrics 9113:9113
# 访问 http://localhost:9113/metrics 查看 metrics
```

---

## 🚀 Step 3: 安装监控栈

### 3.1 创建监控目录结构

```bash
mkdir -p monitoring/{argocd,values}
cd monitoring
```

### 3.2 创建 Loki Application

**`monitoring/argocd/loki.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki
  namespace: argocd
  labels:
    app.kubernetes.io/name: loki
    app.kubernetes.io/component: monitoring
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: https://grafana.github.io/helm-charts
      chart: loki
      targetRevision: 6.0.0
      helm:
        valueFiles:
          - $values/monitoring/values/loki-values.yaml
    - repoURL: https://github.com/leonardsun899/monitoring-stack.git # 替换为你的 Git 仓库地址
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  revisionHistoryLimit: 3
```

### 3.3 创建 Promtail Application

**`monitoring/argocd/promtail.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: promtail
  namespace: argocd
  labels:
    app.kubernetes.io/name: promtail
    app.kubernetes.io/component: monitoring
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: https://grafana.github.io/helm-charts
      chart: promtail
      targetRevision: 6.0.0
      helm:
        valueFiles:
          - $values/monitoring/values/promtail-values.yaml
    - repoURL: https://github.com/leonardsun899/monitoring-stack.git # 替换为你的 Git 仓库地址
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  revisionHistoryLimit: 3
```

### 3.4 创建 Prometheus + Grafana Application

**`monitoring/argocd/prometheus.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: prometheus
  namespace: argocd
  labels:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/component: monitoring
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: https://prometheus-community.github.io/helm-charts
      chart: kube-prometheus-stack
      targetRevision: 60.0.0
      helm:
        valueFiles:
          - $values/monitoring/values/prometheus-values.yaml
    - repoURL: https://github.com/leonardsun899/monitoring-stack.git # 替换为你的 Git 仓库地址
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  revisionHistoryLimit: 3
```

### 3.5 创建 Values 文件

#### 3.5.1 Loki 配置说明

**重要：Loki Helm Chart 默认配置需要 S3 存储**

Loki Helm Chart 的默认配置使用 `SimpleScalable` 模式，**需要 S3 兼容的对象存储**（如 AWS S3）。如果不想使用 S3，需要使用 `SingleBinary` 模式（使用文件系统存储）。

**选项 A：使用 SingleBinary 模式（不需要 S3，推荐用于测试）**

**`monitoring/values/loki-values.yaml`**

```yaml
# Loki 配置 - 使用 SingleBinary 模式（不需要 S3）
# 如果使用默认 Helm Chart 配置（SimpleScalable），需要配置 S3 存储

# 使用单实例模式，使用文件系统存储（不需要 S3）
deploymentMode: SingleBinary

singleBinary:
  enabled: true

# 禁用 SimpleScalable 模式（默认模式需要 S3）
simpleScalable:
  enabled: false
  replicas: 0

# 禁用其他部署模式
read:
  enabled: false
  replicas: 0
write:
  enabled: false
  replicas: 0
backend:
  enabled: false
  replicas: 0

# Loki 基础配置
loki:
  auth_enabled: false
  storage:
    type: filesystem

# 持久化存储（AWS EKS 使用 gp3）
persistence:
  enabled: true
  storageClassName: gp3
  size: 50Gi

# 禁用不需要的组件（SingleBinary 模式）
chunksCache:
  enabled: false
resultsCache:
  enabled: false
gateway:
  enabled: false
canary:
  enabled: false
```

**选项 B：使用默认 SimpleScalable 模式（需要 S3，推荐用于生产）**

如果使用默认 Helm Chart 配置，需要提前配置 S3 存储。详见下面的 **S3 配置说明**。

**`monitoring/values/loki-values-s3.yaml`**（可选，如果使用 S3）

详见文件 `monitoring/values/loki-values-s3.yaml`，该文件支持两种 S3 访问方式：

- **IRSA**（推荐）：不需要配置 `accessKeyId` 和 `secretAccessKey`，AWS SDK 自动从 ServiceAccount 获取凭证
- **IAM 用户访问密钥**：需要创建 Kubernetes Secret，并在配置中指定 Secret 名称

完整配置示例见文件内容。

**S3 配置说明（如果使用选项 B）**

如果选择使用默认的 SimpleScalable 模式，需要提前配置 AWS S3。**推荐使用 IRSA（IAM Roles for Service Accounts）**，这是 AWS EKS 的最佳实践，不需要在 Kubernetes 中存储访问密钥。

#### 方案 1：使用 IRSA（推荐，更安全）

IRSA 允许 Kubernetes ServiceAccount 直接使用 IAM Role，无需存储访问密钥。

**如果使用 Terraform（推荐）：**

Terraform 已经自动完成了所有 IRSA 配置：

- ✅ 创建了 S3 存储桶
- ✅ 创建了 IAM 策略和角色
- ✅ 创建了 Kubernetes ServiceAccount（已配置 IRSA 注解）
- ✅ 创建了 `monitoring` Namespace

你只需要：

1. 运行 `./terraform/update-loki-values.sh` 更新 Loki values 文件（已在 Step 0.6 完成）
2. 确保 `monitoring/values/loki-values-s3.yaml` 中的 `serviceAccount.name` 设置为 `loki-s3-service-account`
3. 修改 `monitoring/argocd/loki.yaml` 中的 `valueFiles` 为 `loki-values-s3.yaml`

**如果手动配置（不使用 Terraform）：**

如果你选择不使用 Terraform，可以按照以下步骤手动配置：

**步骤 1：确保 EKS 集群已配置 OIDC 提供商**

```bash
# 检查集群是否已有 OIDC 提供商
aws eks describe-cluster --name <your-cluster-name> --query "cluster.identity.oidc.issuer" --output text

# 如果没有，创建 OIDC 提供商
eksctl utils associate-iam-oidc-provider --cluster <your-cluster-name> --approve
```

**步骤 2-7：** 按照原始文档中的步骤手动创建 S3、IAM 和 ServiceAccount（详见 Terraform README 或原始文档）

#### 方案 2：使用 IAM 用户访问密钥（备选）

如果无法使用 IRSA，可以使用传统的 IAM 用户访问密钥方式。

**步骤 1：创建 S3 存储桶**

```bash
aws s3 mb s3://loki-storage --region us-west-2
```

**步骤 2：创建 IAM 用户和访问密钥**

1. 在 AWS 控制台创建 IAM 用户（例如：`loki-s3-user`）
2. 附加策略允许访问 S3 存储桶（使用方案 1 中的策略 JSON）
3. 创建访问密钥（Access Key ID 和 Secret Access Key）

**步骤 3：创建 Kubernetes Secret**

```bash
kubectl create secret generic loki-s3-credentials \
  --from-literal=AWS_ACCESS_KEY_ID="你的 Access Key ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="你的 Secret Access Key" \
  --namespace monitoring
```

**步骤 4：配置 Loki 使用访问密钥**

在 `monitoring/values/loki-values-s3.yaml` 中，取消注释并配置：

```yaml
s3:
  secretAccessKey:
    name: loki-s3-credentials
    key: AWS_SECRET_ACCESS_KEY
  accessKeyId:
    name: loki-s3-credentials
    key: AWS_ACCESS_KEY_ID
```

**步骤 5：部署 Loki**

修改 `monitoring/argocd/loki.yaml` 中的 `valueFiles` 为 `loki-values-s3.yaml`。

**两种方案对比：**

| 特性            | IRSA（方案 1）                | IAM 用户（方案 2）         |
| --------------- | ----------------------------- | -------------------------- |
| **安全性**      | ✅ 更高（临时凭证，自动轮换） | ⚠️ 较低（长期凭证）        |
| **配置复杂度**  | ⚠️ 较复杂（需要 OIDC 提供商） | ✅ 较简单                  |
| **需要 Secret** | ❌ 不需要                     | ✅ 需要                    |
| **凭证管理**    | ✅ 自动管理                   | ⚠️ 手动管理                |
| **推荐场景**    | 生产环境                      | 测试环境或无法使用 IRSA 时 |

**推荐方案：**

- **测试环境**：使用选项 A（SingleBinary 模式，不需要 S3）
- **生产环境**：使用选项 B（SimpleScalable 模式，需要 S3，更好的可扩展性）

#### 3.5.2 Promtail 配置

**`monitoring/values/promtail-values.yaml`**

```yaml
# Promtail 配置
# 尽量使用 Helm Chart 默认配置，只覆盖必要的设置

# 配置 Promtail 连接到 Loki
config:
  clients:
    - url: http://loki.monitoring.svc:3100/loki/api/v1/push
```

**说明：**

- Promtail Helm Chart 默认配置已经包含了 Kubernetes Pod 日志收集配置
- 只需要配置 Loki 的连接地址即可
- 其他配置（如资源限制、DaemonSet 等）使用默认值

#### 3.5.3 Prometheus + Grafana 配置

**`monitoring/values/prometheus-values.yaml`**

```yaml
# Prometheus + Grafana 配置
# 尽量使用 Helm Chart 默认配置，只覆盖必要的设置

# Prometheus 配置
prometheus:
  enabled: true
  prometheusSpec:
    retention: 30d
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3 # AWS EKS 使用 gp3
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 100Gi
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false

# Grafana 配置
grafana:
  enabled: true
  # 使用 secret 配置管理员账户（避免模板错误）
  secret:
    admin-user: admin
    admin-password: "admin" # 生产环境请使用强密码
  persistence:
    enabled: true
    storageClassName: gp3 # AWS EKS 使用 gp3
    size: 10Gi
  service:
    type: LoadBalancer # 测试环境使用 LoadBalancer
  # 配置数据源
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          access: proxy
          url: http://prometheus-operated.monitoring.svc:9090
          isDefault: true
        - name: Loki
          type: loki
          access: proxy
          url: http://loki.monitoring.svc:3100
          isDefault: false # 只能有一个默认数据源
  # 预装仪表板
  dashboards:
    default:
      kubernetes-cluster-monitoring:
        gnetId: 7249
        revision: 1
        datasource: Prometheus
      node-exporter:
        gnetId: 1860
        revision: 27
        datasource: Prometheus
      nginx-exporter:
        gnetId: 12708
        revision: 1
        datasource: Prometheus
      loki-logs:
        gnetId: 13639
        revision: 1
        datasource: Loki

# 启用其他组件（使用默认配置）
alertmanager:
  enabled: true
nodeExporter:
  enabled: true
kubeStateMetrics:
  enabled: true
defaultRules:
  create: true
```

**说明：**

- 大部分配置使用 Helm Chart 默认值
- 只覆盖必要的设置（存储类、数据源、仪表板等）
- `storageClassName` 已设置为 `gp3`（AWS EKS）

### 3.6 配置 Loki 使用 S3（如果使用 Terraform）

如果使用 Terraform 创建了集群，需要确保 Loki Application 使用 S3 配置：

**修改 `monitoring/argocd/loki.yaml`：**

```yaml
spec:
  sources:
    - repoURL: https://grafana.github.io/helm-charts
      chart: loki
      targetRevision: 6.0.0
      helm:
        valueFiles:
          - $values/monitoring/values/loki-values-s3.yaml # 使用 S3 配置
    - repoURL: https://github.com/leonardsun899/monitoring-stack.git
      targetRevision: main
      ref: values
```

**验证配置：**

```bash
# 检查 loki-values-s3.yaml 是否已更新
cat monitoring/values/loki-values-s3.yaml | grep -E "(bucketNames|region|serviceAccount)"

# 应该看到：
# chunks: <your-bucket-name>
# region: <your-aws-region>
# name: loki-s3-service-account
```

### 3.7 部署监控栈（按顺序）

```bash
# 1. 部署 Loki（使用 S3 配置）
kubectl apply -f monitoring/argocd/loki.yaml

# 等待 Loki 就绪（可能需要几分钟）
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=loki -n monitoring --timeout=600s

# 检查 Loki Pod 状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki

# 2. 部署 Promtail
kubectl apply -f monitoring/argocd/promtail.yaml

# 3. 部署 Prometheus + Grafana
kubectl apply -f monitoring/argocd/prometheus.yaml

# 4. 等待所有组件就绪
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus -n monitoring --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=300s
```

**注意**：如果 Loki 使用 S3 配置，首次部署可能需要更长时间，因为需要初始化 S3 存储。

---

## 🔍 Step 4: 验证和测试

### 4.1 检查所有组件状态

```bash
# 检查 ArgoCD
kubectl get pods -n argocd

# 检查测试应用
kubectl get pods,svc -n test-app

# 检查监控栈
kubectl get pods,svc -n monitoring

# 检查 ServiceMonitor
kubectl get servicemonitor -n monitoring
```

### 4.2 访问 Grafana

```bash
# 获取 Grafana LoadBalancer 地址
kubectl get svc -n monitoring prometheus-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# 或使用 port-forward
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# 访问 http://localhost:3000 (用户名: admin, 密码: admin)
```

### 4.3 验证 Metrics 收集

**在 Grafana 中：**

1. 进入 **Explore** → 选择 **Prometheus** 数据源
2. 查询 Nginx metrics：
   ```
   nginx_http_requests_total
   ```
3. 查看 Nginx Exporter 仪表板：
   - 进入 **Dashboards** → **Browse**
   - 找到 **Nginx Exporter** 仪表板

### 4.4 验证日志收集

**在 Grafana 中：**

1. 进入 **Explore** → 选择 **Loki** 数据源
2. 查询 Nginx 日志：
   ```
   {namespace="test-app", pod=~"nginx.*"}
   ```
3. 查看日志内容：
   ```
   {namespace="test-app"} |= "GET"
   ```

### 4.5 生成测试流量

```bash
# 获取 Nginx LoadBalancer 地址
NGINX_LB=$(kubectl get svc -n test-app nginx-test-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# 生成测试流量
for i in {1..100}; do
  curl -s http://$NGINX_LB > /dev/null
  sleep 0.1
done

# 然后在 Grafana 中查看 metrics 和 logs
```

---

## 📊 Step 5: 创建自定义仪表板

### 5.1 在 Grafana 中创建 Nginx 监控仪表板

1. 登录 Grafana
2. 进入 **Dashboards** → **New Dashboard**
3. 添加 Panel，使用以下 PromQL 查询：

**Panel 1: Nginx 请求率**

```
rate(nginx_http_requests_total[5m])
```

**Panel 2: Nginx 活跃连接数**

```
nginx_connections_active
```

**Panel 3: Nginx 错误率**

```
rate(nginx_http_requests_total{status=~"5.."}[5m]) / rate(nginx_http_requests_total[5m]) * 100
```

**Panel 4: Nginx 日志（Logs Panel）**

```
{namespace="test-app", pod=~"nginx.*"}
```

### 5.2 保存仪表板

保存为 "Nginx Test App Monitoring"

---

## 🔧 故障排查

### 常见问题

如果遇到部署问题，请参考 [DEBUG.md](./DEBUG.md) 获取详细的故障排查指南。

### ArgoCD 无法同步

```bash
# 检查 ArgoCD 日志
kubectl logs -n argocd deployment/argocd-repo-server

# 检查 Application 状态
kubectl get application -n argocd
kubectl describe application prometheus -n argocd
```

### Loki 部署失败

如果遇到以下错误：

- "Cannot run scalable targets without an object storage backend"
- "You have more than zero replicas configured for both the single binary and simple scalable targets"

解决方案：

1. 检查 `loki-values.yaml` 中是否设置了 `deploymentMode: SingleBinary`
2. 检查是否启用了 `singleBinary.enabled: true`
3. 检查是否禁用了其他模式（simpleScalable, read, write, backend）
4. 参考 [DEBUG.md](./DEBUG.md) 中的问题 1

### nginx-test-app 找不到 values 文件

如果遇到 "no such file or directory" 错误：

1. 检查 `nginx-app.yaml` 是否使用 `sources`（复数）而不是 `source`
2. 确认 Git 仓库 URL 正确
3. 参考 [DEBUG.md](./DEBUG.md) 中的问题 2

### Grafana Pod 无法启动

如果遇到以下错误：

- "secret not found"
- "nil pointer evaluating interface {}.existingSecret"

解决方案：

1. 检查 `prometheus-values.yaml` 中是否**完全移除了 `admin` 配置部分**（不只是注释）
2. 确保只保留 `secret` 配置部分
3. 即使 `admin:` 配置是空的或注释掉的，也会导致模板错误
4. 如果 Secret 仍未创建，可以手动创建（参考 [DEBUG.md](./DEBUG.md) 中的问题 3）
5. 参考 [DEBUG.md](./DEBUG.md) 中的问题 3

### Grafana 数据源配置错误

如果遇到以下错误：

- "Only one datasource per organization can be marked as default"
- Grafana Pod 处于 CrashLoopBackOff 状态

解决方案：

1. 检查 `prometheus-values.yaml` 中的数据源配置
2. 确保只有一个数据源设置了 `isDefault: true`（通常是 Prometheus）
3. 其他数据源（如 Loki）必须设置 `isDefault: false`
4. 参考 [DEBUG.md](./DEBUG.md) 中的问题 4

### Prometheus 无法抓取 Metrics

```bash
# 检查 ServiceMonitor
kubectl get servicemonitor -n monitoring -o yaml

# 检查 Prometheus Targets
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090
# 访问 http://localhost:9090/targets
```

### Promtail 无法收集日志

```bash
# 检查 Promtail 日志
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail --tail=50

# 检查 Promtail 配置
kubectl get configmap -n monitoring promtail -o yaml
```

---

## 📝 快速命令总结

### 完整流程（使用 Terraform）

```bash
# 0. 使用 Terraform 创建 EKS 集群和基础设施
cd terraform
cp terraform.tfvars.example terraform.tfvars
# 编辑 terraform.tfvars
terraform init
terraform plan
terraform apply
terraform output -raw configure_kubectl | bash

# 更新 Loki values 文件
cd ..
./terraform/update-loki-values.sh

# 1. 安装 ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. 获取 ArgoCD 密码
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# 3. 配置 ArgoCD LoadBalancer（可选，用于外部访问）
kubectl apply -f argocd/argocd-server-service.yaml

# 4. 访问 ArgoCD
# 方式 1: 使用 LoadBalancer
kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' && echo
# 方式 2: 使用 port-forward
kubectl port-forward svc/argocd-server -n argocd 8080:443

# 5. 部署测试应用
kubectl apply -f test-app/argocd/nginx-app.yaml

# 6. 部署监控栈（按顺序）
kubectl apply -f monitoring/argocd/loki.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=loki -n monitoring --timeout=300s
kubectl apply -f monitoring/argocd/promtail.yaml
kubectl apply -f monitoring/argocd/prometheus.yaml

# 7. 访问 Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# http://localhost:3000 (admin/admin)
```

### 清理资源（可选）

```bash
# 删除 Kubernetes 资源
kubectl delete -f monitoring/argocd/prometheus.yaml
kubectl delete -f monitoring/argocd/promtail.yaml
kubectl delete -f monitoring/argocd/loki.yaml
kubectl delete -f test-app/argocd/nginx-app.yaml
kubectl delete namespace argocd

# 删除 Terraform 创建的所有资源（包括 EKS 集群）
cd terraform
terraform destroy
```

---

## 📚 参考资源

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Bitnami Nginx Chart](https://github.com/bitnami/charts/tree/main/bitnami/nginx)
- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Loki](https://github.com/grafana/helm-charts/tree/main/charts/loki)
- [Promtail](https://github.com/grafana/helm-charts/tree/main/charts/promtail)
