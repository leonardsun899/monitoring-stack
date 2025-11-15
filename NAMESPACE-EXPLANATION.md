# Namespace 说明

## 📋 概述

在监控栈部署中，涉及到多个不同的 namespace，它们有不同的用途。本文档详细说明它们的区别和关系。

## 🔍 涉及的 Namespace

### 1. `argocd` Namespace

**用途**：存放 ArgoCD 组件和 ArgoCD Application 资源

**包含的资源**：
- ArgoCD 组件（server、repo-server、application-controller 等）
- ArgoCD Application 资源（如 `loki.yaml`、`prometheus.yaml` 等）

**创建方式**：
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

**在配置中的位置**：
```yaml
# monitoring/argocd/loki.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki
  namespace: argocd  # ← Application 资源本身在这里
```

### 2. `monitoring` Namespace

**用途**：存放监控栈的实际应用资源（Pod、Service、Deployment 等）

**包含的资源**：
- Loki Pods 和 Services
- Prometheus Pods 和 Services
- Grafana Pods 和 Services
- Promtail DaemonSet
- ServiceAccount（由 Terraform 创建，用于 IRSA）

**创建方式**：

**方式 A：Terraform 自动创建（当前配置）**
```hcl
# terraform/main.tf
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}
```

**方式 B：ArgoCD 自动创建**
```yaml
# monitoring/argocd/loki.yaml
spec:
  destination:
    namespace: monitoring  # ← 应用部署到这里
  syncOptions:
    - CreateNamespace=true  # ← ArgoCD 会自动创建 namespace
```

**在配置中的位置**：
```yaml
# monitoring/argocd/loki.yaml
spec:
  destination:
    namespace: monitoring  # ← 应用实际部署到这里
```

### 3. `test-app` Namespace

**用途**：存放测试应用（Nginx）

**包含的资源**：
- Nginx Pods 和 Services
- Nginx Metrics Exporter

**创建方式**：ArgoCD 自动创建（`CreateNamespace=true`）

## 🔗 Namespace 之间的关系

```
┌─────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                    │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────────┐         ┌──────────────────┐         │
│  │ argocd       │         │ monitoring       │         │
│  │ namespace    │         │ namespace        │         │
│  ├──────────────┤         ├──────────────────┤         │
│  │              │         │                  │         │
│  │ ArgoCD       │         │ Loki Pods        │         │
│  │ Components   │         │ Prometheus Pods  │         │
│  │              │         │ Grafana Pods     │         │
│  │ Application  │────────▶│ Promtail         │         │
│  │ Resources    │ manages │ ServiceAccount   │         │
│  │ (loki.yaml)  │         │ (IRSA)           │         │
│  │              │         │                  │         │
│  └──────────────┘         └──────────────────┘         │
│                                                          │
│  ┌──────────────┐                                       │
│  │ test-app     │                                       │
│  │ namespace    │                                       │
│  ├──────────────┤                                       │
│  │              │                                       │
│  │ Nginx Pods   │                                       │
│  │              │                                       │
│  └──────────────┘                                       │
└─────────────────────────────────────────────────────────┘
```

## 📊 详细对比

| Namespace | 用途 | 包含的资源类型 | 创建方式 | 是否必需 |
|-----------|------|--------------|---------|---------|
| **`argocd`** | ArgoCD 管理 | ArgoCD 组件、Application 资源 | 手动创建（安装 ArgoCD 时） | ✅ 必需 |
| **`monitoring`** | 监控应用 | Loki、Prometheus、Grafana、Promtail、ServiceAccount | Terraform 或 ArgoCD 自动创建 | ✅ 必需 |
| **`test-app`** | 测试应用 | Nginx | ArgoCD 自动创建 | ⚠️ 可选 |

## ❓ 常见问题

### Q1: Terraform 创建的 `monitoring` namespace 和 ArgoCD 的 `destination.namespace` 是同一个吗？

**A**: 是的！它们是同一个 namespace。

- **Terraform 创建**：提前创建 `monitoring` namespace，确保 ServiceAccount 可以部署
- **ArgoCD 使用**：`destination.namespace: monitoring` 指定应用部署到同一个 namespace

### Q2: 如果 Terraform 已经创建了 `monitoring` namespace，ArgoCD 还会创建吗？

**A**: 不会。如果 namespace 已存在，ArgoCD 会直接使用，不会报错。

即使配置了 `CreateNamespace=true`，如果 namespace 已存在，ArgoCD 会跳过创建步骤。

### Q3: 为什么 Terraform 要提前创建 `monitoring` namespace？

**A**: 主要原因：

1. **ServiceAccount 需要 namespace**：Terraform 创建的 ServiceAccount（用于 IRSA）必须在 namespace 存在后才能创建
2. **确保依赖关系**：确保 namespace 在 ServiceAccount 之前创建
3. **避免竞态条件**：如果让 ArgoCD 自动创建，可能会有时序问题

### Q4: 可以删除 Terraform 中的 namespace 创建，让 ArgoCD 自动创建吗？

**A**: 可以，但需要调整：

**如果删除 Terraform 中的 namespace 创建**：

1. **移除 Terraform 中的 namespace 资源**：
   ```hcl
   # 注释掉或删除
   # resource "kubernetes_namespace" "monitoring" { ... }
   ```

2. **ServiceAccount 需要调整**：
   ```hcl
   # 需要先创建 namespace，或者使用 data source
   data "kubernetes_namespace" "monitoring" {
     metadata {
       name = "monitoring"
     }
   }
   ```

3. **确保 ArgoCD 先创建 namespace**：
   - 先部署 ArgoCD Application
   - 等待 namespace 创建完成
   - 再创建 ServiceAccount

**推荐做法**：保持当前配置（Terraform 创建 namespace），更简单可靠。

### Q5: `argocd` namespace 和 `monitoring` namespace 有什么区别？

**A**: 主要区别：

| 特性 | `argocd` namespace | `monitoring` namespace |
|------|-------------------|----------------------|
| **用途** | ArgoCD 管理资源 | 应用运行环境 |
| **资源类型** | ArgoCD 组件、Application 资源 | 应用 Pods、Services、Deployments |
| **谁创建** | 手动创建（安装 ArgoCD 时） | Terraform 或 ArgoCD |
| **谁管理** | ArgoCD 自己 | ArgoCD Application |
| **可见性** | ArgoCD UI 中显示 Application | 应用实际运行的地方 |

## 🎯 总结

1. **`argocd` namespace**：ArgoCD 的家，存放 ArgoCD 组件和 Application 资源
2. **`monitoring` namespace**：监控应用的家，存放 Loki、Prometheus、Grafana 等
3. **`test-app` namespace**：测试应用的家，存放 Nginx

**关键点**：
- Terraform 创建的 `monitoring` namespace 和 ArgoCD 的 `destination.namespace: monitoring` **是同一个**
- Terraform 提前创建是为了确保 ServiceAccount 可以正确部署
- ArgoCD Application 资源在 `argocd` namespace，但管理的应用部署在 `monitoring` namespace

