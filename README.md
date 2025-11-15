# ArgoCD Application 配置

## 📋 当前配置（默认，推荐）

所有 Application 资源都部署在 `argocd` namespace，这是最简单和推荐的配置。

### Application 文件

- `loki.yaml` - Loki 日志聚合
- `prometheus.yaml` - Prometheus + Grafana 监控
- `promtail.yaml` - Promtail 日志收集

### 配置说明

```yaml
metadata:
  namespace: argocd  # Application 资源在 argocd namespace
spec:
  destination:
    namespace: monitoring  # 应用部署到 monitoring namespace
```

**优点**：
- ✅ 无需额外配置
- ✅ ArgoCD 默认监控 `argocd` namespace
- ✅ 开箱即用
- ✅ 可以在 ArgoCD UI 中直接看到所有应用

## 🔧 可选配置

### ApplicationSet（可选）

`applicationset.yaml` 是可选的配置文件，用于将 Application 资源部署到 `monitoring` namespace。

**何时使用**：
- 需要将 Application 资源也放到 `monitoring` namespace
- 需要更复杂的 GitOps 自动化场景

**如何使用**：
1. 参考 `ARGOCD-NAMESPACE-CONFIGURATION.md` 文档
2. 配置 ArgoCD 监控 `monitoring` namespace
3. 部署 ApplicationSet

**注意**：对于大多数场景，不需要使用 ApplicationSet，保持默认配置即可。

## 🚀 快速开始

### 部署所有 Application

```bash
# 部署监控组件
kubectl apply -f monitoring/argocd/loki.yaml
kubectl apply -f monitoring/argocd/prometheus.yaml
kubectl apply -f monitoring/argocd/promtail.yaml

# 部署测试应用
kubectl apply -f test-app/argocd/nginx-app.yaml
```

### 查看 Application 状态

```bash
# 查看所有 Application
kubectl get applications -n argocd

# 查看特定 Application 详情
kubectl get application loki -n argocd -o yaml
```

### 在 ArgoCD UI 中查看

1. 访问 ArgoCD UI（通过 LoadBalancer 或 port-forward）
2. 登录后，在 Applications 页面会看到所有应用
3. 所有应用都会显示，无论它们部署到哪个 namespace

## 📚 参考文档

- `ARGOCD-NAMESPACE-CONFIGURATION.md` - 详细的 namespace 配置说明
- `COMPLETE-MONITORING-STACK-SETUP.md` - 完整的安装指南

