# 监控栈部署问题排查指南

本文档记录了在部署监控栈过程中遇到的问题、原因分析和解决方案。

## 📋 问题概览

在初始部署后，ArgoCD 应用状态显示以下问题：

| 应用名称       | 同步状态 | 健康状态 | 问题描述                          |
| -------------- | -------- | -------- | --------------------------------- |
| loki           | Unknown  | Healthy  | 无法生成清单：需要对象存储后端    |
| nginx-test-app | Unknown  | Healthy  | 找不到 values 文件路径            |
| prometheus     | Synced   | Degraded | Grafana Pod 无法启动：缺少 Secret |
| promtail       | Synced   | Healthy  | ✅ 正常                           |

---

## 🔍 问题 1: Loki - 对象存储后端错误和组件 Pending 问题

### 错误信息

**初始错误：**

```
Failed to load target state: failed to generate manifest for source 1 of 2:
rpc error: code = Unknown desc = Manifest generation error (cached):
failed to execute helm template command:
Error: execution error at (loki/templates/validate.yaml:19:4):
Cannot run scalable targets (backend, read, write) or distributed targets
without an object storage backend.
```

**后续问题：**

- `loki-chunks-cache-0` Pod 处于 `Pending` 状态
- Application 健康状态显示为 `Progressing` 而不是 `Healthy`
- Helm 模板验证错误："You have more than zero replicas configured for both the single binary and simple scalable targets"

### 原因分析

1. **初始问题**：Loki Helm Chart 6.0.0 版本默认使用分布式模式（distributed mode），该模式需要配置对象存储后端（如 S3、GCS、Azure Blob 等）。但我们的配置使用的是 `filesystem` 存储类型，这会导致验证失败。

2. **Pending 问题**：在 SingleBinary 模式下，缓存组件（chunksCache、resultsCache）和 Gateway 不是必需的，但 Helm Chart 默认会尝试创建它们，导致资源分配问题或配置冲突。

3. **Replicas 冲突问题**：即使设置了 `simpleScalable.enabled: false`，如果 `replicas` 没有显式设置为 `0`，Helm Chart 验证会失败，因为默认值可能不是 0。

### 解决方案

在 `monitoring/values/loki-values.yaml` 中启用单实例模式（singleBinary），并**必须**禁用所有不必要的组件：

```yaml
# Loki 配置
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  limits_config:
    retention_period: 720h
    ingestion_rate_mb: 16
    ingestion_burst_size_mb: 32
    max_query_parallelism: 32
    max_query_series: 500

# 使用单实例模式，不需要对象存储
# 重要：必须设置 deploymentMode，否则会报错
deploymentMode: SingleBinary

singleBinary:
  enabled: true
  replicas: 1

# 禁用其他部署模式（必须显式禁用，且 replicas 必须设置为 0）
simpleScalable:
  enabled: false
  replicas: 0 # 必须显式设置为 0，否则会与 singleBinary 冲突
read:
  enabled: false
  replicas: 0
write:
  enabled: false
  replicas: 0
backend:
  enabled: false
  replicas: 0

# 持久化存储
persistence:
  enabled: true
  storageClassName: do-block-storage
  size: 50Gi

# 资源限制
resources:
  requests:
    cpu: 200m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 2Gi

# Service 配置
service:
  type: ClusterIP
  port: 3100

# 禁用所有缓存组件（SingleBinary 模式不需要）
chunksCache:
  enabled: false

resultsCache:
  enabled: false

# 禁用 Gateway（SingleBinary 模式直接使用 Service）
# 组件应该直接访问 loki Service: http://loki.monitoring.svc:3100
gateway:
  enabled: false

# 禁用 Canary（测试组件，非必需）
canary:
  enabled: false

# 禁用其他不必要的组件
monitoring:
  dashboards:
    enabled: false
  rules:
    enabled: false
  serviceMonitor:
    enabled: false
```

**关键点：**

- `deploymentMode: SingleBinary` 是必需的，告诉 Helm Chart 使用单实例模式
- 必须显式禁用其他模式（simpleScalable, read, write, backend），**且必须将 replicas 设置为 0**，否则 Helm Chart 验证会失败
- **必须禁用缓存组件**（chunksCache、resultsCache），否则会导致 Pod Pending
- **建议禁用 Gateway**，让组件直接访问 Loki Service，简化架构
- 如果只设置 `singleBinary.enabled: true` 而不设置 `deploymentMode`，会出现错误："You have more than zero replicas configured for both the single binary and simple scalable targets"
- **重要**：即使 `enabled: false`，也必须显式设置 `replicas: 0`，因为 Helm Chart 的默认值可能不是 0

### 验证

```bash
# 检查 Loki Application 状态
kubectl get application loki -n argocd

# 检查 Loki Pod 状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki

# 查看 Loki 日志
kubectl logs -n monitoring -l app.kubernetes.io/name=loki --tail=50
```

---

## 🔍 问题 2: nginx-test-app - 找不到 values 文件

### 错误信息

```
Failed to load target state: failed to generate manifest for source 1 of 1:
rpc error: code = Unknown desc = Manifest generation error (cached):
failed to execute helm template command:
Error: open /tmp/.../nginx/test-app/values/nginx-values.yaml:
no such file or directory
```

### 原因分析

`nginx-app.yaml` 中使用了 `$values/test-app/values/nginx-values.yaml` 来引用 values 文件，但配置中只指定了 Helm Chart 仓库，没有指定 Git 仓库作为 values 的来源。ArgoCD 无法找到 values 文件的位置。

### 解决方案

修改 `test-app/argocd/nginx-app.yaml`，使用 `sources`（复数）而不是 `source`，并添加 Git 仓库作为第二个 source：

```yaml
spec:
  project: default
  sources: # 注意：使用 sources（复数）
    - repoURL: https://charts.bitnami.com/bitnami
      chart: nginx
      targetRevision: 15.0.0
      helm:
        valueFiles:
          - $values/test-app/values/nginx-values.yaml
    - repoURL: https://github.com/leonardsun899/monitoring-stack.git
      targetRevision: main
      ref: values # 这个 ref 告诉 ArgoCD 这是 values 文件的来源
```

**关键点：**

- 使用 `sources`（复数）支持多个仓库源
- 第一个 source 是 Helm Chart 仓库
- 第二个 source 是 Git 仓库，用于提供 values 文件
- `ref: values` 标识这个 source 用于 values 文件

### 验证

```bash
# 检查 nginx-test-app Application 状态
kubectl get application nginx-test-app -n argocd

# 检查 Nginx Pod 状态
kubectl get pods -n test-app

# 检查 ServiceMonitor 是否创建
kubectl get servicemonitor -n monitoring
```

---

## 🔍 问题 3: Prometheus/Grafana - Secret 不存在

### 错误信息

```bash
kubectl describe pod prometheus-grafana-xxx -n monitoring

Events:
  Warning  Failed  Error: secret "grafana-admin-credentials" not found
```

### 原因分析

`prometheus-values.yaml` 中配置了：

```yaml
grafana:
  admin:
    existingSecret: grafana-admin-credentials
    userKey: admin-user
    passwordKey: admin-password
```

这告诉 Grafana 使用已存在的 Secret，但该 Secret 并不存在。Grafana Helm Chart 应该自动创建 Secret，但配置中指定了 `existingSecret`，导致它不会自动创建。

### 解决方案

**完全移除 `admin` 配置部分**，只保留 `secret` 配置。如果保留空的 `admin:` 配置，会导致 Helm 模板错误：

```yaml
grafana:
  enabled: true
  # 不配置 admin 部分，让 Helm chart 使用默认配置
  # admin 配置会导致模板错误，使用 secret 配置即可
  secret:
    admin-user: admin
    admin-password: "admin" # 生产环境请使用强密码
```

**错误示例（会导致模板错误）：**

```yaml
grafana:
  enabled: true
  admin:
    # 即使注释掉，空的 admin 配置也会导致错误
    # existingSecret: grafana-admin-credentials
  secret:
    admin-user: admin
    admin-password: "admin"
```

**错误信息：**

```
Error: template: kube-prometheus-stack/charts/grafana/templates/secret.yaml:1:27:
executing "kube-prometheus-stack/charts/grafana/templates/secret.yaml" at <.Values.admin.existingSecret>:
nil pointer evaluating interface {}.existingSecret
```

**说明：**

- 如果配置了 `admin:` 部分（即使是空的），Helm Chart 会尝试访问 `admin.existingSecret`，导致 nil pointer 错误
- 完全移除 `admin` 配置，只使用 `secret` 配置，Helm Chart 会自动创建 Secret
- 生产环境建议使用 Kubernetes Secret 管理工具（如 Sealed Secrets、External Secrets）

### 验证

```bash
# 检查 Grafana Pod 状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana

# 检查 Secret 是否创建
kubectl get secret -n monitoring | grep grafana

# 查看 Grafana Pod 日志
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana --tail=50
```

### 临时解决方案：手动创建 Secret

如果移除了 `admin` 配置后，Helm Chart 仍然没有自动创建 Secret，可以手动创建：

```bash
kubectl create secret generic grafana-admin-credentials -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=admin

# 然后删除 Pod 让它重新创建
kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana
```

**注意**: 这个 Secret 名称 `grafana-admin-credentials` 是 Grafana Helm Chart 的默认名称。如果配置了不同的名称，需要相应修改。

---

## 🔍 问题 4: Grafana - 数据源配置错误

### 错误信息

```bash
kubectl logs -n monitoring prometheus-grafana-xxx -c grafana

Error: ✗ Datasource provisioning error: datasource.yaml config is invalid.
Only one datasource per organization can be marked as default
```

### 原因分析

在 `prometheus-values.yaml` 中配置了多个数据源（Prometheus 和 Loki），如果都设置了 `isDefault: true`，Grafana 会报错，因为每个组织只能有一个默认数据源。

### 解决方案

确保只有一个数据源设置为 `isDefault: true`，其他数据源设置为 `isDefault: false` 或不设置（默认为 false）：

```yaml
grafana:
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          access: proxy
          url: http://prometheus-operated.monitoring.svc:9090
          isDefault: true # 只有 Prometheus 设置为默认
          editable: true
        - name: Loki
          type: loki
          access: proxy
          url: http://loki.monitoring.svc:3100
          isDefault: false # 重要：必须设置为 false
          editable: true
```

**关键点：**

- 只能有一个数据源的 `isDefault: true`
- 其他数据源必须显式设置 `isDefault: false` 或不设置该字段
- 通常 Prometheus 作为默认数据源，因为大多数查询都是 PromQL

### 验证

```bash
# 检查 Grafana Pod 状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana

# 查看 Grafana 日志，确认没有数据源错误
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -c grafana --tail=50 | grep -i datasource

# 如果 Pod 在 CrashLoopBackOff，查看完整日志
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -c grafana --tail=100
```

---

## 🔍 问题 5: ArgoCD Server 无法外部访问

### 问题描述

默认情况下，ArgoCD Server 使用 ClusterIP 类型，只能通过 `kubectl port-forward` 在本地访问。如果需要从外部网络访问，需要将其改为 LoadBalancer 类型。

### 解决方案

**方式 1: 使用配置文件（推荐，持久化）**

```bash
# 应用 Service 配置
kubectl apply -f argocd/argocd-server-service.yaml

# 等待 LoadBalancer 分配 IP
kubectl get svc -n argocd argocd-server -w
```

**方式 2: 使用 kubectl patch（临时）**

```bash
# 临时修改为 LoadBalancer
kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"LoadBalancer"}}'
```

**注意**:

- 使用配置文件的方式更好，因为配置保存在 Git 仓库中，可以版本控制
- 使用 patch 的方式在 ArgoCD 重新同步时可能会被覆盖

### 获取 LoadBalancer 地址

```bash
# 获取 LoadBalancer IP 或 Hostname
kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' && echo
# 或
kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' && echo
```

### 访问 ArgoCD UI

1. 使用 LoadBalancer 地址访问：

   - HTTP: `http://<loadbalancer-ip-or-hostname>`
   - HTTPS: `https://<loadbalancer-ip-or-hostname>`

2. 登录信息：
   - 用户名: `admin`
   - 密码: 运行以下命令获取
     ```bash
     kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
     ```

### 安全建议

⚠️ **生产环境建议**:

- 使用 Ingress + TLS 证书而不是直接暴露 LoadBalancer
- 配置 OIDC/SSO 认证
- 使用 NetworkPolicy 限制访问
- 考虑使用 ClusterIP + Ingress Controller（如 ALB、NGINX Ingress）

### 验证

```bash
# 检查 Service 类型
kubectl get svc -n argocd argocd-server

# 应该显示 TYPE 为 LoadBalancer，EXTERNAL-IP 有值
# NAME            TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)
# argocd-server   LoadBalancer   10.109.10.68   170.64.245.57   80:31797/TCP,443:32213/TCP
```

---

## 🔍 问题 6: Prometheus - EBS CSI Driver 未安装导致 PVC 无法绑定

### 错误信息

```bash
kubectl get pvc -n monitoring
# STATUS: Pending
# Events: no persistent volumes available for this claim and no storage class is set

kubectl get pods -n monitoring
# prometheus-prometheus-kube-prometheus-prometheus-0: Pending
# prometheus-grafana-xxx: Pending
```

### 原因分析

1. **EBS CSI Driver 未安装**：AWS EKS 集群默认不包含 EBS CSI Driver，需要手动安装才能动态创建 EBS 卷
2. **PVC 无法绑定**：没有可用的 StorageClass 或 CSI Driver，PVC 无法自动创建 PersistentVolume
3. **Pod 无法调度**：由于 PVC 未绑定，依赖这些 PVC 的 Pod 无法调度

### 解决方案

**方式 1: 通过 Terraform 安装（推荐）**

在 `terraform/main.tf` 中添加 EBS CSI Driver 资源：

```hcl
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
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = "v1.32.0-eksbuild.1" # Use latest compatible version
  service_account_role_arn = aws_iam_role.ebs_csi_driver.arn
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
```

然后运行：

```bash
terraform apply
```

**方式 2: 手动安装（如果 CSI Driver 已存在）**

如果集群中已经存在 EBS CSI Driver，可以通过变量控制 Terraform 不创建：

```hcl
variable "create_ebs_csi_driver" {
  description = "Whether to create EBS CSI Driver add-on"
  type        = bool
  default     = true
}

resource "aws_eks_addon" "ebs_csi_driver" {
  count = var.create_ebs_csi_driver ? 1 : 0
  # ... rest of configuration
}
```

**方式 3: 使用 kubectl 手动安装**

```bash
# 安装 EBS CSI Driver
kubectl apply -k "github.com/kubernetes-sigs/aws-ebs-csi-driver/deploy/kubernetes/overlays/stable/?ref=release-1.32"

# 或使用 Helm
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --set controller.serviceAccount.create=false \
  --set controller.serviceAccount.name=ebs-csi-controller-sa
```

### 验证

```bash
# 检查 EBS CSI Driver Pod 状态
kubectl get pods -n kube-system | grep ebs-csi

# 应该看到类似输出：
# ebs-csi-controller-xxx   6/6     Running   0   5m
# ebs-csi-node-xxx          3/3     Running   0   5m

# 检查 StorageClass
kubectl get storageclass

# 应该看到 gp3 或 ebs-sc 等 StorageClass

# 检查 PVC 状态
kubectl get pvc -n monitoring

# 等待一段时间后，PVC 应该从 Pending 变为 Bound
```

---

## 🔍 问题 7: Prometheus - Grafana 数据源配置冲突

### 错误信息

```bash
kubectl logs -n monitoring prometheus-grafana-xxx -c grafana

Error: ✗ Datasource provisioning error: datasource.yaml config is invalid.
Only one datasource per organization can be marked as default
```

### 原因分析

1. **多个数据源配置冲突**：kube-prometheus-stack 会自动创建 `prometheus-kube-prometheus-grafana-datasource` ConfigMap，其中包含 Prometheus (isDefault: true)
2. **重复配置**：在 `prometheus-values.yaml` 中使用 `datasources` 配置会创建 `prometheus-grafana` ConfigMap，也包含 Prometheus (isDefault: true)
3. **Grafana 加载冲突**：Grafana 会加载所有带有 `grafana_datasource: "1"` 标签的 ConfigMap，导致多个默认数据源冲突

### 解决方案

**使用 `additionalDataSources` 而不是 `datasources`**

修改 `monitoring/values/prometheus-values.yaml`：

```yaml
grafana:
  enabled: true
  # ... 其他配置 ...

  # ❌ 错误方式：会覆盖默认配置，导致冲突
  # datasources:
  #   datasources.yaml:
  #     apiVersion: 1
  #     datasources:
  #       - name: Prometheus
  #         isDefault: true
  #       - name: Loki
  #         isDefault: false

  # ✅ 正确方式：使用 additionalDataSources 添加额外数据源
  additionalDataSources:
    - name: Loki
      type: loki
      access: proxy
      url: http://loki.monitoring.svc:3100
      isDefault: false # Prometheus 已经由 kube-prometheus-stack 设置为默认
      editable: true
```

**如果已经创建了冲突的 ConfigMap，需要删除：**

```bash
# 删除冲突的 ConfigMap（kube-prometheus-stack 会自动创建正确的）
kubectl delete configmap prometheus-grafana -n monitoring

# 删除 Grafana Pod 让它重新加载配置
kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana

# 等待 Pod 重新创建
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -w
```

**手动修复 ConfigMap（临时方案）：**

```bash
# 编辑 ConfigMap，确保只有一个 isDefault: true
kubectl edit configmap prometheus-kube-prometheus-grafana-datasource -n monitoring

# 或使用 patch
kubectl patch configmap prometheus-kube-prometheus-grafana-datasource -n monitoring \
  --type='json' \
  -p='[{"op": "add", "path": "/data/datasource.yaml", "value": "apiVersion: 1\ndatasources:\n- name: Prometheus\n  isDefault: true\n- name: Loki\n  isDefault: false"}]'
```

### 验证

```bash
# 检查数据源 ConfigMap
kubectl get configmap -n monitoring -l grafana_datasource

# 应该只有一个 ConfigMap：prometheus-kube-prometheus-grafana-datasource

# 检查 ConfigMap 内容
kubectl get configmap prometheus-kube-prometheus-grafana-datasource -n monitoring -o yaml

# 确保只有一个数据源的 isDefault: true

# 检查 Grafana Pod 日志
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -c grafana --tail=50

# 应该没有数据源配置错误
```

---

## 🔍 问题 8: Grafana Pod 一直 Pending - 节点资源不足

### 错误信息

```bash
kubectl describe pod -n monitoring prometheus-grafana-xxx

Events:
  Warning  FailedScheduling  0/2 nodes are available: 2 Too many pods.
  preemption: 0/2 nodes are available: 2 No preemption victims found for incoming pod.
```

### 原因分析

1. **节点 Pod 数量限制**：每个节点有最大 Pod 数量限制（通常由 CNI 和节点配置决定）
2. **资源耗尽**：节点上已经运行了太多 Pod，无法调度新的 Pod
3. **集群规模不足**：对于监控栈（Prometheus、Grafana、Loki 等），需要足够的节点资源

### 解决方案

**方式 1: 扩展节点（推荐）**

```bash
# 检查节点资源
kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name) pods: \(.status.allocatable.pods)"'

# 检查当前运行的 Pod 数量
kubectl get pods --all-namespaces --field-selector=status.phase=Running --no-headers | wc -l

# 如果节点资源不足，需要扩展 EKS 节点组
# 在 Terraform 中增加节点数量或节点类型
```

**方式 2: 清理不必要的 Pod**

```bash
# 检查所有命名空间的 Pod
kubectl get pods --all-namespaces

# 删除不必要的 Pod 或应用
# 注意：只删除确定不需要的资源
```

**方式 3: 等待其他 Pod 完成**

如果有一些 Job 或临时 Pod 正在运行，等待它们完成后会自动释放资源。

### 验证

```bash
# 检查节点资源
kubectl top nodes  # 如果 metrics-server 已安装

# 检查 Pod 调度状态
kubectl get pods -n monitoring -o wide

# 等待资源释放后，Pending 的 Pod 应该会自动调度
```

---

## 🔍 问题 9: Loki - StatefulSet volumeClaimTemplates 缺少 storageClassName

### 错误信息

```bash
kubectl get pvc -n monitoring | grep loki
# STATUS: Pending
# StorageClass: <unset>

kubectl describe pvc data-loki-backend-0 -n monitoring
# Events: no persistent volumes available for this claim and no storage class is set
```

### 原因分析

1. **StatefulSet 限制**：Kubernetes StatefulSet 的 `volumeClaimTemplates` 字段无法直接修改（只能修改 replicas、template、updateStrategy 等）
2. **Helm Chart 配置问题**：虽然 values 文件中配置了 `simpleScalable.backend.persistence.storageClassName: gp3`，但 Helm Chart 可能没有正确应用到 StatefulSet 的 volumeClaimTemplates
3. **PVC 无法绑定**：没有 storageClassName 的 PVC 无法被 EBS CSI Driver 动态创建

### 解决方案

**方式 1: 手动 Patch 现有 PVC（临时方案）**

```bash
# 为所有 Loki PVC 添加 storageClassName
for pvc in $(kubectl get pvc -n monitoring -o name | grep loki); do
  kubectl patch $pvc -n monitoring --type='merge' -p '{"spec":{"storageClassName":"gp3"}}'
done

# 检查 PVC 状态
kubectl get pvc -n monitoring | grep loki
```

**方式 2: 删除并重新创建 StatefulSet（推荐）**

由于 StatefulSet 的 volumeClaimTemplates 无法直接修改，需要删除 StatefulSet 让 Helm 重新创建：

```bash
# 删除 StatefulSet（保留 PVC，因为数据可能重要）
kubectl delete statefulset loki-backend loki-write -n monitoring --cascade=orphan

# 触发 ArgoCD 重新同步
kubectl annotate application loki -n argocd argocd.argoproj.io/refresh=hard --overwrite
kubectl patch application loki -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main","prune":true}}}'

# 等待 StatefulSet 重新创建
kubectl get statefulset -n monitoring | grep loki
```

**注意**：如果 Helm Chart 的配置路径不正确，StatefulSet 重新创建后可能还是没有 storageClassName。需要检查 Helm Chart 的文档，确认正确的配置路径。

**方式 3: 更新 Helm Values 文件**

确保 `monitoring/values/loki-values-s3.yaml` 中正确配置了 storageClassName：

```yaml
simpleScalable:
  backend:
    persistence:
      enabled: true
      storageClassName: gp3
      size: 10Gi
  write:
    persistence:
      enabled: true
      storageClassName: gp3
      size: 10Gi
```

### 验证

```bash
# 检查 StatefulSet 的 volumeClaimTemplates
kubectl get statefulset loki-backend -n monitoring -o jsonpath='{.spec.volumeClaimTemplates[0].spec.storageClassName}'
# 应该输出: gp3

# 检查 PVC 状态
kubectl get pvc -n monitoring | grep loki
# 应该显示 storageClassName: gp3，并且 STATUS 为 Bound 或 Pending（等待 Pod 调度）

# 检查 Pod 状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki
```

---

## 🔍 问题 10: Loki Pod CrashLoopBackOff - Schema 配置未生效

### 错误信息

```bash
kubectl logs -n monitoring loki-backend-0 -c loki

Error: CONFIG ERROR: schema v13 is required to store Structured Metadata and use native OTLP ingestion,
your schema version is v11. Set `allow_structured_metadata: false` in the `limits_config` section...
CONFIG ERROR: `tsdb` index type is required to store Structured Metadata and use native OTLP ingestion,
your index type is `boltdb-shipper`...
```

### 原因分析

1. **配置未同步**：虽然 values 文件中已经更新为 schema v13 和 tsdb，但 ArgoCD 可能还没有同步，或者 ConfigMap 还没有更新
2. **Loki 版本要求**：Loki 3.0.0 版本要求使用 schema v13 和 tsdb 索引类型
3. **配置缓存**：Helm Chart 可能缓存了旧的配置

### 解决方案

**步骤 1: 确认 values 文件配置正确**

检查 `monitoring/values/loki-values-s3.yaml`：

```yaml
loki:
  schemaConfig:
    configs:
      - from: "2020-10-24"
        store: tsdb # 必须是 tsdb，不是 boltdb-shipper
        object_store: s3
        schema: v13 # 必须是 v13，不是 v11
        index:
          prefix: index_
          period: 24h
  limits_config:
    allow_structured_metadata: false # 必须设置为 false
```

**步骤 2: 触发 ArgoCD 重新同步**

```bash
# 刷新 ArgoCD Application
kubectl annotate application loki -n argocd argocd.argoproj.io/refresh=hard --overwrite

# 手动触发同步
kubectl patch application loki -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main","prune":true}}}'

# 等待同步完成
kubectl get application loki -n argocd -w
```

**步骤 3: 检查 ConfigMap 是否更新**

```bash
# 检查 Loki ConfigMap
kubectl get configmap loki -n monitoring -o yaml | grep -A 10 "schemaConfig:"

# 应该看到 store: tsdb 和 schema: v13
```

**步骤 4: 重启 Loki Pod**

```bash
# 删除 Pod 让它们重新创建并加载新配置
kubectl delete pod -n monitoring -l app.kubernetes.io/name=loki

# 等待 Pod 重新创建
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki -w
```

### 验证

```bash
# 检查 Pod 日志，确认没有配置错误
kubectl logs -n monitoring loki-backend-0 -c loki --tail=50

# 应该没有 schema 或 index type 相关的错误

# 检查 Pod 状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki
# 应该从 CrashLoopBackOff 变为 Running
```

---

## 🔍 问题 11: Grafana Pod Pending - Volume Node Affinity Conflict

### 错误信息

```bash
kubectl describe pod -n monitoring prometheus-grafana-xxx

Events:
  Warning  FailedScheduling  0/4 nodes are available: 1 node(s) had volume node affinity conflict
```

### 原因分析

1. **EBS Volume Zone 绑定**：Grafana 的 PVC 已经绑定到特定 Availability Zone（如 `ap-southeast-2c`）
2. **节点分布**：集群中的节点可能不在该 zone，或者该 zone 的节点资源不足
3. **WaitForFirstConsumer 模式**：`gp3` StorageClass 使用 `WaitForFirstConsumer` 模式，PVC 会在 Pod 调度后绑定，但如果 PVC 已经绑定，Pod 必须调度到该 volume 所在的 zone

### 解决方案

**方式 1: 检查节点 Zone 分布**

```bash
# 查看所有节点的 zone
kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name) zone: \(.metadata.labels."topology.kubernetes.io/zone")"'

# 查看 Grafana PVC 绑定的 zone
kubectl get pv $(kubectl get pvc prometheus-grafana -n monitoring -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}'
```

**方式 2: 删除 Pod 让调度器重新调度**

如果 PVC 绑定的 zone 有可用节点，删除 Pod 让它重新调度：

```bash
# 删除 Grafana Pod
kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana

# 等待 Pod 重新创建并调度
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -w
```

**方式 3: 删除 PVC 重新创建（如果数据不重要）**

如果 Grafana 的数据不重要，可以删除 PVC 让调度器重新创建：

```bash
# 删除 Grafana Pod 和 PVC
kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana
kubectl delete pvc prometheus-grafana -n monitoring

# 等待 Pod 和 PVC 重新创建
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -w
kubectl get pvc -n monitoring | grep grafana
```

**方式 4: 扩展节点到 PVC 所在的 Zone**

如果 PVC 绑定的 zone 没有节点或节点资源不足，可以扩展节点：

```bash
# 检查节点组配置，确保在 PVC 所在的 zone 有节点
# 在 Terraform 中配置多个 Availability Zone
```

### 验证

```bash
# 检查 Pod 调度状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o wide

# 检查 Pod 是否调度到正确的节点（与 PVC 在同一 zone）
kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].spec.nodeName}'
kubectl get node <node-name> -o jsonpath='{.metadata.labels."topology.kubernetes.io/zone"}'
```

---

## 🔍 问题 12: 节点资源不足导致 Pod 无法调度

### 错误信息

```bash
kubectl describe pod -n monitoring <pod-name>

Events:
  Warning  FailedScheduling  0/4 nodes are available: 4 Too many pods.
  preemption: 0/4 nodes are available: 4 No preemption victims found for incoming pod.
```

### 原因分析

1. **节点 Pod 数量限制**：每个节点有最大 Pod 数量限制（通常由 CNI 和节点配置决定，如 17 个 Pod/节点）
2. **资源耗尽**：节点上已经运行了太多 Pod，无法调度新的 Pod
3. **监控栈资源需求**：监控栈（Prometheus、Grafana、Loki 等）需要较多资源

### 解决方案

**方式 1: 扩展节点数量（推荐）**

```bash
# 检查当前节点数和 Pod 分布
kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name) pods: \(.status.allocatable.pods)"'
kubectl get pods --all-namespaces -o wide --field-selector=status.phase=Running --no-headers | awk '{print $8}' | sort | uniq -c

# 使用 AWS CLI 扩展节点组
aws eks update-nodegroup-config \
  --cluster-name eks-test \
  --nodegroup-name <nodegroup-name> \
  --scaling-config desiredSize=4,maxSize=4 \
  --region ap-southeast-2

# 或使用 Terraform
# 修改 terraform/variables.tf 中的 node_desired_size 和 node_max_size
terraform apply
```

**方式 2: 等待临时 Pod 完成**

如果有一些 Job 或临时 Pod 正在运行，等待它们完成后会自动释放资源：

```bash
# 检查 Job 状态
kubectl get jobs --all-namespaces

# 等待 Job 完成
kubectl wait --for=condition=complete job/<job-name> -n <namespace> --timeout=300s
```

**方式 3: 清理不必要的 Pod**

```bash
# 检查所有命名空间的 Pod
kubectl get pods --all-namespaces

# 删除不必要的 Pod 或应用
# 注意：只删除确定不需要的资源
```

### 验证

```bash
# 检查节点资源
kubectl get nodes -o custom-columns=NAME:.metadata.name,PODS:.status.allocatable.pods

# 检查当前运行的 Pod 数量
kubectl get pods --all-namespaces --field-selector=status.phase=Running --no-headers | wc -l

# 检查 Pod 调度状态
kubectl get pods -n monitoring --field-selector=status.phase=Pending -o wide

# 等待资源释放后，Pending 的 Pod 应该会自动调度
```

---

## 🔍 问题 13: Grafana Pod Pending - 删除 PVC 重新创建解决 Volume Node Affinity Conflict

### 问题描述

Grafana Pod 一直处于 Pending 状态，错误信息显示 `volume node affinity conflict`。

### 原因分析

1. **PVC 已绑定到特定 Zone**：Grafana 的 PVC 已经绑定到特定的 Availability Zone（如 `ap-southeast-2c`）
2. **节点资源不足**：该 zone 的节点资源不足，无法调度 Pod
3. **WaitForFirstConsumer 模式**：`gp3` StorageClass 使用 `WaitForFirstConsumer` 模式，但如果 PVC 已经绑定，Pod 必须调度到该 volume 所在的 zone

### 解决方案

**如果 Grafana 数据不重要，删除 PVC 让调度器重新创建：**

```bash
# 删除 Grafana Pod
kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana

# 删除 Grafana PVC（数据会丢失，但会重新创建）
kubectl delete pvc prometheus-grafana -n monitoring

# 等待 Pod 和 PVC 重新创建
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -w
kubectl get pvc -n monitoring | grep grafana
```

**注意**：删除 PVC 会导致 Grafana 的数据（仪表板、用户配置等）丢失。如果数据重要，应该：

1. 先备份数据
2. 或等待节点资源释放
3. 或扩展节点到 PVC 所在的 zone

### 验证

```bash
# 检查 Pod 状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana

# 应该从 Pending 变为 Running

# 检查 PVC 状态
kubectl get pvc -n monitoring | grep grafana

# 新的 PVC 应该已经 Bound
```

---

## 🔍 问题 14: Loki Schema 配置更新后需要提交到 Git 并重启 Pod

### 问题描述

虽然更新了 `loki-values-s3.yaml` 文件（schema v13, tsdb），但 Loki Pod 仍然报错，显示配置还是 v11 和 boltdb-shipper。

### 原因分析

1. **配置未提交到 Git**：values 文件的更改只存在于本地，没有提交到 Git 仓库
2. **ArgoCD 未同步**：ArgoCD 从 Git 仓库读取配置，本地更改不会自动同步
3. **Pod 使用旧配置**：即使 ConfigMap 更新了，Pod 可能还在使用旧的配置缓存

### 解决方案

**步骤 1: 提交配置到 Git**

```bash
# 检查未提交的更改
git status monitoring/values/loki-values-s3.yaml

# 添加并提交更改
git add monitoring/values/loki-values-s3.yaml
git commit -m "fix: Update Loki schema to v13 and tsdb, add storageClassName configuration"
git push origin main
```

**步骤 2: 触发 ArgoCD 同步**

```bash
# 刷新 ArgoCD Application
kubectl annotate application loki -n argocd argocd.argoproj.io/refresh=hard --overwrite

# 手动触发同步
kubectl patch application loki -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main","prune":true}}}'

# 等待同步完成
kubectl get application loki -n argocd -w
```

**步骤 3: 验证 ConfigMap 已更新**

```bash
# 检查 Loki ConfigMap
kubectl get configmap loki -n monitoring -o yaml | grep -A 3 "store:\|schema:"

# 应该看到 store: tsdb 和 schema: v13
```

**步骤 4: 重启 Loki Pod 加载新配置**

```bash
# 删除所有 Loki Pod 让它们重新创建并加载新配置
kubectl delete pod -n monitoring -l app.kubernetes.io/name=loki

# 等待 Pod 重新创建
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki -w
```

### 验证

```bash
# 检查 Pod 日志，确认没有配置错误
kubectl logs -n monitoring loki-backend-0 -c loki --tail=50

# 应该没有 schema 或 index type 相关的错误

# 检查 Pod 状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki
# 应该从 CrashLoopBackOff 变为 Running
```

---

## 🔍 问题 15: Loki S3 Bucket 名称不匹配

### 问题描述

Loki ConfigMap 中配置的 S3 bucket 名称与 Terraform 实际创建的 bucket 名称不匹配，导致 S3 访问失败。

### 错误信息

```bash
# 检查 ConfigMap 中的 bucket 名称
kubectl get configmap loki -n monitoring -o yaml | grep bucketnames
# 输出: bucketnames: eks-test-loki-storage-d6756e1c

# 检查 Terraform 输出的 bucket 名称
terraform output loki_s3_bucket_name
# 输出: eks-test-loki-storage-565c7d68

# 验证 bucket 是否存在
aws s3 ls s3://eks-test-loki-storage-d6756e1c/
# 错误: NoSuchBucket
```

### 原因分析

**根本原因：自动化脚本与文件格式不匹配，导致配置无法自动同步**

1. **Terraform 使用随机后缀生成 bucket 名称**

   - Terraform 配置使用 `random_id.bucket_suffix.hex` 生成 8 位随机十六进制后缀
   - 格式：`${cluster_name}-loki-storage-${random_id.bucket_suffix.hex}`
   - 每次 `terraform apply`（特别是 destroy 后重新创建）可能生成不同的后缀
   - 例如：`eks-test-loki-storage-d6756e1c` -> `eks-test-loki-storage-565c7d68`

2. **自动化脚本期望的格式与实际文件不匹配**

   - `terraform/update-loki-values.sh` 脚本期望在 `loki-values-s3.yaml` 中找到占位符：
     - `${LOKI_S3_BUCKET_NAME}`
     - `${AWS_REGION}`
   - 脚本使用 `sed` 命令替换这些占位符：
     ```bash
     sed -e "s|\${LOKI_S3_BUCKET_NAME}|${BUCKET_NAME}|g" \
         -e "s|\${AWS_REGION}|${AWS_REGION}|g" \
         "${VALUES_FILE}"
     ```
   - 但实际文件中是硬编码的 bucket 名称：`eks-test-loki-storage-d6756e1c`
   - 脚本找不到占位符，无法进行替换，导致配置无法自动更新

3. **配置同步缺失**

   - 当 Terraform 重新创建资源时（如 `terraform destroy` 后 `terraform apply`），bucket 名称会变化
   - 但 `loki-values-s3.yaml` 文件中的 bucket 名称没有同步更新
   - 如果脚本没有运行，或者脚本无法找到占位符，配置就会保持旧值
   - 导致 Loki 尝试访问不存在的 bucket（旧的 bucket 名称）

4. **工作流程问题**
   - 脚本应该在 `terraform apply` 后自动运行，但可能被遗漏
   - 或者文件应该使用占位符而不是硬编码值
   - 或者应该使用 Terraform 的 `local_file` 资源自动生成 values 文件

### 解决方案

**步骤 1: 获取正确的 bucket 名称**

```bash
# 从 Terraform 输出获取
cd terraform
terraform output loki_s3_bucket_name

# 或从 AWS 直接查看
aws s3 ls | grep loki
```

**步骤 2: 更新 values 文件**

编辑 `monitoring/values/loki-values-s3.yaml`：

```yaml
loki:
  storage:
    bucketNames:
      chunks: eks-test-loki-storage-565c7d68 # 使用正确的 bucket 名称
      ruler: eks-test-loki-storage-565c7d68 # 使用正确的 bucket 名称
```

**步骤 3: 提交到 Git 并同步**

```bash
# 提交更改
git add monitoring/values/loki-values-s3.yaml
git commit -m "fix: Update Loki S3 bucket name to match Terraform output"
git push origin main

# 触发 ArgoCD 同步
kubectl annotate application loki -n argocd argocd.argoproj.io/refresh=hard --overwrite
kubectl patch application loki -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main","prune":true}}}'
```

**步骤 4: 验证 ConfigMap 已更新**

```bash
# 检查 ConfigMap
kubectl get configmap loki -n monitoring -o yaml | grep -A 2 "bucketnames:"

# 应该显示正确的 bucket 名称
```

**步骤 5: 重启 Loki Pod**

```bash
# 删除 Pod 让它们重新加载配置
kubectl delete pod -n monitoring -l app.kubernetes.io/name=loki
```

### 验证

```bash
# 检查 ConfigMap 中的 bucket 名称
kubectl get configmap loki -n monitoring -o yaml | grep bucketnames

# 应该显示正确的 bucket 名称（与 Terraform 输出一致）

# 检查 Pod 日志，确认没有 bucket 相关的错误
kubectl logs -n monitoring loki-backend-0 -c loki --tail=50 | grep -i bucket
```

---

## 🔍 问题 16: Loki S3 访问错误 - MethodNotAllowed

### 错误信息

```bash
kubectl logs -n monitoring loki-backend-0 -c loki

level=error msg="sync failed, retrying it" err="WebIdentityErr: failed to retrieve credentials
caused by: SerializationError: failed to unmarshal error message
    status code: 405, request id:
caused by: UnmarshalError: failed to unmarshal error message
    <Error><Code>MethodNotAllowed</Code><Message>The specified method is not allowed against this resource.</Message>
    <Method>POST</Method><ResourceType>SERVICE</ResourceType>
```

### 原因分析

1. **STS (Security Token Service) 调用问题**：错误信息显示 `ResourceType: SERVICE` 和 `Method: POST`，表明这是 STS 调用问题，而不是直接的 S3 访问问题
2. **IRSA 配置**：虽然日志中有错误，但 IRSA 配置看起来是正确的（ServiceAccount 有正确的 IAM Role 注解，IAM Role 有正确的信任策略和权限）
3. **AWS SDK 行为**：可能是 AWS SDK 在尝试某些操作时使用了错误的方法，但重试后成功
4. **功能影响**：虽然日志中有错误，但 Loki 的基本功能（写入和查询）是正常的

### 排查步骤

**步骤 1: 检查 ServiceAccount 和 IAM Role**

```bash
# 检查 ServiceAccount
kubectl get serviceaccount loki-s3-service-account -n monitoring -o yaml

# 检查 IAM Role ARN
kubectl get serviceaccount loki-s3-service-account -n monitoring -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'

# 检查 IAM Role 信任策略
aws iam get-role --role-name eks-test-loki-s3-role --query 'Role.AssumeRolePolicyDocument' --output json
```

**步骤 2: 检查 S3 Bucket 配置**

```bash
# 检查 Loki ConfigMap 中的 S3 bucket 配置
kubectl get configmap loki -n monitoring -o yaml | grep -A 5 "bucketnames:"

# 验证 S3 bucket 是否存在
aws s3 ls | grep loki
aws s3api head-bucket --bucket eks-test-loki-storage-565c7d68
```

**步骤 3: 检查 IAM Role 权限**

```bash
# 获取 IAM Role 名称
ROLE_ARN=$(kubectl get serviceaccount loki-s3-service-account -n monitoring -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')
ROLE_NAME=$(echo $ROLE_ARN | awk -F'/' '{print $2}')

# 检查 IAM Role 的策略
aws iam list-attached-role-policies --role-name $ROLE_NAME
aws iam get-policy-version --policy-arn arn:aws:iam::ACCOUNT:policy/POLICY_NAME --version-id VERSION_ID
```

**步骤 4: 验证 Loki 功能**

虽然日志中有错误，但需要验证 Loki 是否真的可以正常工作：

```bash
# 测试写入数据
kubectl exec -n monitoring loki-gateway-64c9b8cc4d-rctp7 -- wget -qO- --post-data='{"streams":[{"stream":{"job":"test"},"values":[["'$(date +%s)000000000'","test message"]]}]}' --header='Content-Type: application/json' http://localhost:8080/loki/api/v1/push

# 测试查询数据
kubectl exec -n monitoring loki-gateway-64c9b8cc4d-rctp7 -- wget -qO- 'http://localhost:8080/loki/api/v1/query?query={job="test"}'

# 检查日志中的成功操作
kubectl logs -n monitoring loki-backend-0 -c loki --tail=200 | grep -E "(downloaded|uploaded|success)"
```

### 实际测试结果

经过测试，发现：

1. ✅ **Loki 可以成功写入数据**：POST 请求成功，没有错误
2. ✅ **Loki 可以成功查询数据**：查询返回了刚才写入的测试消息
3. ✅ **日志中有成功操作**：`downloaded index set at query time` 表明某些操作是成功的
4. ⚠️ **日志中仍有错误**：`MethodNotAllowed` 错误仍然存在，但似乎不影响基本功能

### 结论

虽然日志中有 `MethodNotAllowed` 错误，但 Loki 的基本功能（写入和查询）是正常的。这些错误可能是：

1. **某些特定操作失败**：如 index 表的初始化操作失败，但不影响基本功能
2. **AWS SDK 行为**：AWS SDK 在尝试某些操作时使用了错误的方法，但重试后成功
3. **不影响核心功能**：写入和查询功能正常，说明 S3 访问权限是足够的

### 建议

1. **继续观察**：如果 Loki 功能正常，可以暂时忽略这些错误日志
2. **监控功能**：定期检查 Loki 是否真的在写入和查询数据
3. **升级 Loki 版本**：如果问题持续，可以考虑升级 Loki 版本，可能修复了某些 AWS SDK 相关的问题
4. **检查 AWS SDK 版本**：某些 AWS SDK 版本可能有已知的 STS endpoint 问题

### 验证

```bash
# 检查 Loki Pod 状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki

# 应该大部分 Pod 都是 Running 状态

# 测试 Loki 功能
kubectl exec -n monitoring loki-gateway-64c9b8cc4d-rctp7 -- wget -qO- http://localhost:8080/loki/api/v1/labels

# 应该返回标签列表，说明 Loki 功能正常
```

---

## 🔍 问题 16: loki-chunks-cache-0 Pod 一直 Pending

### 错误信息

```bash
kubectl describe pod -n monitoring loki-chunks-cache-0

Events:
  Warning  FailedScheduling  0/4 nodes are available: 4 Insufficient memory, 4 Too many pods.
```

### 原因分析

1. **节点资源不足**：所有节点都资源不足（内存和 Pod 数量）
2. **资源需求较大**：`loki-chunks-cache-0` 需要较多内存资源
3. **节点数量不足**：即使扩展到 4 个节点，监控栈的资源需求仍然很大

### 解决方案

**方式 1: 等待资源释放**

如果有一些临时 Pod 或 Job 正在运行，等待它们完成后会自动释放资源：

```bash
# 检查 Job 状态
kubectl get jobs --all-namespaces

# 等待 Job 完成
kubectl wait --for=condition=complete job/<job-name> -n <namespace> --timeout=300s
```

**方式 2: 扩展节点（如果资源持续不足）**

```bash
# 继续扩展节点数量
aws eks update-nodegroup-config \
  --cluster-name eks-test \
  --nodegroup-name <nodegroup-name> \
  --scaling-config desiredSize=5,maxSize=5 \
  --region ap-southeast-2
```

**方式 3: 减少 loki-chunks-cache 的资源请求（推荐）**

如果希望保留 chunks-cache 但减少资源需求，可以在 values 文件中配置更小的资源请求：

在 `monitoring/values/loki-values-s3.yaml` 中添加：

```yaml
# Cache components configuration
# Reduce resource requests to fit within node capacity
chunksCache:
  enabled: true
  resources:
    requests:
      cpu: 500m
      memory: 1Gi # Reduced from default 9830Mi to fit node capacity (~3.8GB)
    limits:
      memory: 2Gi # Allow some burst but limit to prevent OOM

resultsCache:
  enabled: true
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      memory: 1Gi
```

**步骤：**

1. 更新 values 文件并提交到 Git
2. 触发 ArgoCD 同步：
   ```bash
   kubectl annotate application loki -n argocd argocd.argoproj.io/refresh=hard --overwrite
   kubectl patch application loki -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main","prune":true}}}'
   ```
3. 等待 StatefulSet 更新并 Pod 重新创建
4. 验证 Pod 状态：
   ```bash
   kubectl get pods -n monitoring loki-chunks-cache-0
   ```

**方式 4: 禁用 loki-chunks-cache（如果不需要）**

如果 chunks-cache 不是必需的，可以在 values 文件中禁用它：

```yaml
chunksCache:
  enabled: false
```

### 验证

```bash
# 检查 Pod 调度状态
kubectl get pods -n monitoring loki-chunks-cache-0 -o wide

# 应该显示 Running 状态，并且已调度到某个节点

# 检查资源请求是否已更新
kubectl get statefulset -n monitoring loki-chunks-cache -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq .

# 应该显示：
# {
#   "limits": {
#     "memory": "2Gi"
#   },
#   "requests": {
#     "cpu": "500m",
#     "memory": "1Gi"
#   }
# }

# 检查所有 Loki Pod 状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki

# 应该所有 Pod 都是 Running 状态
```

### 实际结果

通过减少资源请求成功解决了问题：

- ✅ **资源请求已更新**：从 9830Mi 减少到 1Gi
- ✅ **Pod 成功调度**：`loki-chunks-cache-0` 现在 Running 状态
- ✅ **保留了缓存功能**：chunksCache 仍然启用，只是使用更少的资源
- ✅ **所有 Loki Pod 正常运行**：16 个 Loki Pod 都在 Running 状态

**优势：**

- 保留了 chunksCache 的缓存功能，提高查询性能
- 不需要增加节点或升级节点规格
- 不需要完全禁用缓存组件

---

## 📚 附录：Loki chunksCache 详解

### chunksCache 的作用

`chunksCache` 是 Loki 的**块缓存组件**，用于提高查询性能：

1. **缓存日志数据块（Chunks）**

   - Loki 将日志数据存储在 S3 等对象存储中的"块"（chunks）
   - chunksCache 缓存这些块，避免每次查询都从 S3 读取
   - 显著减少对后端存储的访问频率

2. **加速查询响应**

   - 缓存常用的日志块，使查询更快
   - 特别是在高并发查询场景下，效果明显
   - 减少网络延迟和存储 I/O

3. **降低存储成本**
   - 减少对 S3 的 API 调用次数
   - 降低数据传输成本

### 为什么默认需要大内存（9830Mi ≈ 9.6GB）？

**原因：Memcached 默认配置需要 8GB 内存**

从 StatefulSet 配置可以看到，chunksCache 使用 **Memcached** 作为缓存后端：

```yaml
containers:
  - name: memcached
    image: memcached:1.6.23-alpine
    args:
      - -m 8192 # 分配 8192MB (8GB) 内存给 Memcached
      - --extended=modern,track_sizes
      - -I 5m # 最大 item 大小 5MB
      - -c 16384 # 最大连接数 16384
```

**内存分配说明：**

1. **Memcached 内存限制**：`-m 8192` 表示 Memcached 可以使用最多 8GB 内存
2. **Kubernetes 资源请求**：9830Mi（约 9.6GB）包括：

   - Memcached 的 8GB 内存
   - 操作系统和其他进程的额外内存（约 1.6GB）
   - 安全余量，防止 OOM（Out of Memory）

3. **为什么需要这么大？**
   - **生产环境考虑**：在生产环境中，可能有大量的日志数据需要缓存
   - **性能优化**：更大的缓存可以存储更多的数据块，减少缓存未命中
   - **高并发场景**：支持更多的并发查询和连接

### 减少资源后的影响

当我们将内存请求从 9830Mi 减少到 1Gi 时：

1. **Memcached 内存限制会相应调整**

   - 实际可用的缓存内存会减少（可能只有几百 MB）
   - 缓存容量变小，缓存未命中率可能增加

2. **性能影响**

   - ✅ **小规模场景**：影响不大，仍然有缓存效果
   - ⚠️ **大规模场景**：可能影响查询性能，需要更多从 S3 读取
   - ⚠️ **高并发场景**：缓存可能不够用，性能下降

3. **建议**
   - **测试/开发环境**：1-2Gi 足够
   - **小规模生产环境**：2-4Gi 可以接受
   - **大规模生产环境**：建议保持 8GB 或更多，并相应增加节点资源

### 如何调整 Memcached 内存限制

Loki Helm Chart 支持通过 `allocatedMemory` 参数配置 Memcached 的内存限制：

```yaml
chunksCache:
  enabled: true
  # 调整 Memcached 分配的内存（MB）
  # 这个值应该小于或等于 Kubernetes limits.memory
  allocatedMemory: 1024 # 1GB，从默认的 8192MB 减少
  maxItemMemory: 5 # MB，最大 item 大小
  connectionLimit: 16384
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      memory: 2Gi # 应该大于 allocatedMemory
```

**重要**：

- `allocatedMemory` 是 Memcached 实际可用的内存（MB）
- 应该小于或等于 Kubernetes `limits.memory`
- 如果 `allocatedMemory` 大于 `limits.memory`，Memcached 可能被 OOMKilled
- 建议：`allocatedMemory` ≤ `limits.memory` - 200MB（留出系统开销）

### 总结

- **chunksCache 的作用**：缓存日志数据块，加速查询，减少 S3 访问
- **默认大内存的原因**：Memcached 默认配置需要 8GB 内存，加上系统开销约 9.6GB
- **减少资源的影响**：缓存容量变小，可能影响大规模/高并发场景的性能
- **建议**：根据实际使用场景调整，测试环境可以小，生产环境建议保持较大

---

## 🔧 通用排查步骤

### 1. 检查 ArgoCD Application 状态

```bash
# 查看所有应用状态
kubectl get application -n argocd

# 查看详细状态和错误信息
kubectl describe application <app-name> -n argocd

# 查看应用事件
kubectl get events -n argocd --field-selector involvedObject.name=<app-name>
```

### 2. 检查 ArgoCD 日志

```bash
# 查看 ArgoCD Repo Server 日志（处理 Git 和 Helm 仓库）
kubectl logs -n argocd deployment/argocd-repo-server --tail=100

# 查看 ArgoCD Application Controller 日志
kubectl logs -n argocd deployment/argocd-application-controller --tail=100
```

### 3. 检查 Pod 状态

```bash
# 检查特定命名空间的 Pod
kubectl get pods -n <namespace>

# 查看 Pod 详细信息和事件
kubectl describe pod <pod-name> -n <namespace>

# 查看 Pod 日志
kubectl logs <pod-name> -n <namespace>
```

### 4. 验证 Git 仓库连接

```bash
# 在 ArgoCD UI 中检查
# Settings → Repositories → 查看仓库连接状态

# 或使用 ArgoCD CLI
argocd repo list
```

### 5. 手动触发同步

```bash
# 使用 kubectl
kubectl patch application <app-name> -n argocd \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'

# 或使用 ArgoCD CLI
argocd app sync <app-name>
```

---

## 📝 修复后的配置检查清单

- [ ] Loki 配置包含 `deploymentMode: SingleBinary` 和 `singleBinary.enabled: true`
- [ ] Loki 配置禁用了其他模式（simpleScalable, read, write, backend）
- [ ] nginx-app.yaml 使用 `sources`（复数）并包含 Git 仓库
- [ ] Grafana 配置**完全移除了 `admin` 部分**（不只是注释）
- [ ] Grafana 配置只保留 `secret` 部分
- [ ] Grafana 数据源配置中，只有一个数据源设置了 `isDefault: true`
- [ ] 其他数据源（如 Loki）的 `isDefault` 设置为 `false`
- [ ] ArgoCD Server Service 已配置为 LoadBalancer（如果需要外部访问）
- [ ] 所有存储类配置正确（根据实际环境修改）
- [ ] Git 仓库 URL 正确
- [ ] 所有 values 文件已提交到 Git 仓库

---

## 🚀 快速修复命令

如果遇到相同问题，可以快速应用修复：

```bash
# 1. 拉取最新代码
git pull origin main

# 2. 应用修复后的配置
kubectl apply -f monitoring/argocd/loki.yaml
kubectl apply -f monitoring/argocd/prometheus.yaml
kubectl apply -f test-app/argocd/nginx-app.yaml

# 3. 配置 ArgoCD LoadBalancer（如果需要外部访问）
kubectl apply -f argocd/argocd-server-service.yaml

# 4. 等待同步完成
kubectl get application -n argocd -w

# 5. 检查 Pod 状态
kubectl get pods -n monitoring
kubectl get pods -n test-app

# 6. 检查 Service 状态
kubectl get svc -n argocd argocd-server
kubectl get svc -n monitoring prometheus-grafana
```

---

## 📚 参考资源

- [Loki Helm Chart 文档](https://github.com/grafana/helm-charts/tree/main/charts/loki)
- [ArgoCD Multi-Source Applications](https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/)
- [Grafana Helm Chart 文档](https://github.com/grafana/helm-charts/tree/main/charts/grafana)
- [ArgoCD 故障排查](https://argo-cd.readthedocs.io/en/stable/operator-manual/troubleshooting/)
