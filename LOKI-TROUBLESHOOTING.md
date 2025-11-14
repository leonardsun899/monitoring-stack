# Loki Sync Error 故障排查指南

如果 Loki 应用仍然出现 sync error，请按照以下步骤排查：

## 🔍 步骤 1: 获取详细的错误信息

### 方法 1: 在 ArgoCD UI 中查看

1. 打开 ArgoCD UI
2. 点击 `loki` 应用
3. 查看 **"Conditions"** 或 **"Events"** 部分
4. 复制完整的错误信息

### 方法 2: 使用 kubectl 查看

```bash
# 查看 Application 状态和条件
kubectl get application loki -n argocd -o yaml

# 查看 Application 的详细状态
kubectl describe application loki -n argocd

# 查看 ArgoCD Application Controller 日志
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=100 | grep -i loki

# 查看 ArgoCD Repo Server 日志（处理 Helm Chart）
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100 | grep -i loki
```

## 🔍 步骤 2: 检查常见问题

### 问题 1: ArgoCD 缓存问题

ArgoCD 可能缓存了旧的配置。尝试清除缓存：

```bash
# 方法 1: 在 ArgoCD UI 中
# 点击应用 → 点击 "Refresh" 按钮

# 方法 2: 使用 kubectl
kubectl patch application loki -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# 方法 3: 删除并重新创建 Application（最后手段）
kubectl delete application loki -n argocd
kubectl apply -f monitoring/argocd/loki.yaml
```

### 问题 2: Helm Chart 版本问题

检查 Helm Chart 版本是否兼容：

```yaml
# monitoring/argocd/loki.yaml
spec:
  sources:
    - repoURL: https://grafana.github.io/helm-charts
      chart: loki
      targetRevision: 6.0.0  # 检查这个版本
```

如果问题持续，可以尝试：
- 使用更稳定的版本（如 `5.x.x`）
- 或使用最新版本（检查 [Loki Helm Chart Releases](https://github.com/grafana/helm-charts/releases)）

### 问题 3: Values 文件路径问题

检查 ArgoCD 是否能正确找到 values 文件：

```bash
# 检查 Git 仓库连接
kubectl get application loki -n argocd -o yaml | grep -A 10 sources

# 验证 Git 仓库中的文件路径
# 确保文件存在于: monitoring/values/loki-values.yaml
```

### 问题 4: 配置验证问题

尝试使用 Helm 直接验证配置：

```bash
# 在本地测试 Helm 模板渲染
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm template loki grafana/loki --version 6.0.0 \
  -f monitoring/values/loki-values.yaml \
  --namespace monitoring \
  --debug
```

## 🔧 步骤 3: 尝试最小化配置

如果问题持续，尝试使用最小化配置：

```yaml
# monitoring/values/loki-values.yaml
deploymentMode: SingleBinary

singleBinary:
  enabled: true
  replicas: 1

simpleScalable:
  enabled: false
  replicas: 0

read:
  enabled: false
  replicas: 0

write:
  enabled: false
  replicas: 0

backend:
  enabled: false
  replicas: 0

loki:
  auth_enabled: false
  storage:
    type: filesystem

persistence:
  enabled: true
  storageClassName: do-block-storage
  size: 50Gi

chunksCache:
  enabled: false

resultsCache:
  enabled: false

gateway:
  enabled: false

canary:
  enabled: false
```

## 📋 步骤 4: 提供错误信息

请提供以下信息以便进一步排查：

1. **完整的错误信息**（从 ArgoCD UI 或 kubectl 输出）
2. **ArgoCD 版本**
3. **Kubernetes 版本**
4. **Helm Chart 版本**（当前是 6.0.0）

## 🚀 快速修复尝试

如果急需解决，可以尝试：

```bash
# 1. 清除 ArgoCD 缓存并强制刷新
kubectl patch application loki -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# 2. 等待几秒钟，然后检查状态
kubectl get application loki -n argocd

# 3. 如果还是失败，查看详细错误
kubectl describe application loki -n argocd
```

---

**请运行上述命令并分享具体的错误信息，这样我可以提供更精确的解决方案。**

