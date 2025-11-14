# 监控栈部署问题排查指南

本文档记录了在部署监控栈过程中遇到的问题、原因分析和解决方案。

## 📋 问题概览

在初始部署后，ArgoCD 应用状态显示以下问题：

| 应用名称 | 同步状态 | 健康状态 | 问题描述 |
|---------|---------|---------|---------|
| loki | Unknown | Healthy | 无法生成清单：需要对象存储后端 |
| nginx-test-app | Unknown | Healthy | 找不到 values 文件路径 |
| prometheus | Synced | Degraded | Grafana Pod 无法启动：缺少 Secret |
| promtail | Synced | Healthy | ✅ 正常 |

---

## 🔍 问题 1: Loki - 对象存储后端错误

### 错误信息

```
Failed to load target state: failed to generate manifest for source 1 of 2: 
rpc error: code = Unknown desc = Manifest generation error (cached): 
failed to execute helm template command: 
Error: execution error at (loki/templates/validate.yaml:19:4): 
Cannot run scalable targets (backend, read, write) or distributed targets 
without an object storage backend.
```

### 原因分析

Loki Helm Chart 6.0.0 版本默认使用分布式模式（distributed mode），该模式需要配置对象存储后端（如 S3、GCS、Azure Blob 等）。但我们的配置使用的是 `filesystem` 存储类型，这会导致验证失败。

### 解决方案

在 `monitoring/values/loki-values.yaml` 中启用单实例模式（singleBinary），这样可以使用本地文件系统存储，不需要对象存储：

```yaml
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
singleBinary:
  replicas: 1
  enabled: true

persistence:
  enabled: true
  storageClassName: do-block-storage  # 根据实际环境修改
  size: 50Gi
```

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
  sources:  # 注意：使用 sources（复数）
    - repoURL: https://charts.bitnami.com/bitnami
      chart: nginx
      targetRevision: 15.0.0
      helm:
        valueFiles:
          - $values/test-app/values/nginx-values.yaml
    - repoURL: https://github.com/leonardsun899/monitoring-stack.git
      targetRevision: main
      ref: values  # 这个 ref 告诉 ArgoCD 这是 values 文件的来源
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

移除 `existingSecret` 配置，让 Helm Chart 自动创建 Secret：

```yaml
grafana:
  enabled: true
  admin:
    # 移除 existingSecret，让 Helm chart 自动创建 secret
    # existingSecret: grafana-admin-credentials
    # userKey: admin-user
    # passwordKey: admin-password
  secret:
    admin-user: admin
    admin-password: "admin"  # 生产环境请使用强密码
```

**说明：**
- 如果指定了 `existingSecret`，Helm Chart 不会创建新的 Secret
- 移除后，Helm Chart 会根据 `secret` 部分自动创建 Secret
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

- [ ] Loki 配置包含 `singleBinary.enabled: true`
- [ ] nginx-app.yaml 使用 `sources`（复数）并包含 Git 仓库
- [ ] Grafana 配置移除了 `existingSecret`
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

# 3. 等待同步完成
kubectl get application -n argocd -w

# 4. 检查 Pod 状态
kubectl get pods -n monitoring
kubectl get pods -n test-app
```

---

## 📚 参考资源

- [Loki Helm Chart 文档](https://github.com/grafana/helm-charts/tree/main/charts/loki)
- [ArgoCD Multi-Source Applications](https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/)
- [Grafana Helm Chart 文档](https://github.com/grafana/helm-charts/tree/main/charts/grafana)
- [ArgoCD 故障排查](https://argo-cd.readthedocs.io/en/stable/operator-manual/troubleshooting/)

