# ArgoCD Namespace 配置说明

## 📋 概述

本文档说明 ArgoCD Application 资源的 namespace 配置，以及如何在 ArgoCD UI 中查看应用。

## 🔍 两个重要的 Namespace 概念

在 ArgoCD 配置中，有两个不同的 namespace 概念：

1. **Application 资源所在的 namespace**（`metadata.namespace`）
   - 这是 ArgoCD Application 资源本身所在的 namespace
   - 决定了 ArgoCD 在哪里查找和管理 Application 资源

2. **应用部署到的 namespace**（`destination.namespace`）
   - 这是 Application 管理的实际应用部署到的 namespace
   - 可以是任何 namespace（如 `monitoring`、`test-app` 等）

## ✅ 当前配置（推荐）

### 配置结构

```
Application 资源位置: argocd namespace
    ↓ (管理)
应用部署位置: monitoring namespace
```

### 当前配置示例

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki
  namespace: argocd  # Application 资源在 argocd namespace
spec:
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring  # 应用部署到 monitoring namespace
```

### 优点

- ✅ **默认行为**：ArgoCD 默认监控 `argocd` namespace 中的 Application
- ✅ **集中管理**：所有 Application 资源集中在一个地方
- ✅ **权限清晰**：ArgoCD 在 `argocd` namespace 有完整权限
- ✅ **无需额外配置**：开箱即用

## 🖥️ 在 ArgoCD UI 中查看应用

### 当前配置已可在 ArgoCD UI 看到

**重要**：当前配置下，这些应用**已经可以在 ArgoCD UI 中看到**，无需额外配置！

### 工作原理

```
ArgoCD 默认行为：
├── 监控 argocd namespace 中的所有 Application 资源
├── 在 UI 中显示这些 Application
└── 无论 Application 管理的应用部署在哪个 namespace
```

### 查看步骤

1. **访问 ArgoCD UI**
   ```bash
   # 方式 1: 使用 LoadBalancer
   kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   # 访问 http://<loadbalancer-ip>
   
   # 方式 2: 使用 port-forward
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   # 访问 https://localhost:8080
   ```

2. **登录 ArgoCD**
   - 用户名：`admin`
   - 密码：从 secret 获取
     ```bash
     kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
     ```

3. **查看应用**
   在 Applications 页面会看到：
   - `loki` - 部署到 `monitoring` namespace
   - `prometheus` - 部署到 `monitoring` namespace
   - `promtail` - 部署到 `monitoring` namespace
   - `nginx-test-app` - 部署到 `test-app` namespace

这些应用会显示它们管理的资源在相应的 namespace。

## ⚙️ 配置 ArgoCD 监控其他 Namespace

如果需要将 Application 资源放到其他 namespace（如 `monitoring`），需要额外配置。

### 方法 1：修改 ArgoCD ConfigMap（推荐用于简单场景）

#### 步骤

1. **编辑 ArgoCD ConfigMap**
   ```bash
   kubectl edit configmap argocd-cmd-params-cm -n argocd
   ```

2. **添加配置**
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: argocd-cmd-params-cm
     namespace: argocd
   data:
     application.namespaces: argocd,monitoring  # 添加要监控的 namespace
   ```

3. **重启 ArgoCD Application Controller**
   ```bash
   kubectl rollout restart deployment argocd-application-controller -n argocd
   ```

4. **验证配置**
   ```bash
   # 检查 Application Controller 日志
   kubectl logs -n argocd deployment/argocd-application-controller --tail=50
   
   # 应该看到类似输出：
   # level=info msg="Watching namespaces: argocd,monitoring"
   ```

#### 注意事项

- 需要确保 ArgoCD 有权限访问目标 namespace
- 修改后需要重启 Application Controller
- 适用于需要监控少量 namespace 的场景

### 方法 2：使用 ApplicationSet（更灵活，推荐用于复杂场景）

ApplicationSet 可以自动从 Git 仓库发现并创建 Application，更灵活且支持 GitOps。

#### 创建 ApplicationSet 配置

**`monitoring/argocd/applicationset.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: monitoring-stack
  namespace: monitoring  # ApplicationSet 在 monitoring namespace
  labels:
    app.kubernetes.io/name: monitoring-stack
    app.kubernetes.io/component: argocd
spec:
  generators:
  # Merge generator: combines Git directory discovery with Application definitions
  - merge:
      generators:
        # Discover Application YAML files in Git repository
        - git:
            repoURL: https://github.com/leonardsun899/monitoring-stack.git
            revision: main
            directories:
            - path: monitoring/argocd/*
              exclude: "applicationset.yaml"  # Exclude ApplicationSet itself
      mergeKeys:
        - name  # Merge based on Application name
      template:
        metadata:
          # Override namespace to monitoring (original files have argocd)
          namespace: monitoring
          labels:
            app.kubernetes.io/part-of: monitoring-stack
            app.kubernetes.io/managed-by: applicationset
        spec:
          # The Application spec will be read from the Git repository files
          # Only override namespace if needed
          destination:
            namespace: monitoring
```

**说明**：
- 使用 **merge generator** 从 Git 仓库读取现有的 Application 定义
- 自动覆盖 `metadata.namespace` 为 `monitoring`
- 保留原有 Application 的所有配置（sources、syncPolicy 等）
- 只需在 Git 仓库中添加新的 Application 文件，ApplicationSet 会自动发现并创建

#### 部署 ApplicationSet

**重要**：ApplicationSet 需要单独部署，有两种方式：

##### 方式 1：手动部署（推荐，首次部署）

```bash
# 1. 首先配置 ArgoCD 监控 monitoring namespace（方法 1）
kubectl edit configmap argocd-cmd-params-cm -n argocd
# 添加: application.namespaces: argocd,monitoring

kubectl rollout restart deployment argocd-application-controller -n argocd

# 2. 确保 monitoring namespace 存在
kubectl create namespace monitoring

# 3. 手动部署 ApplicationSet（首次部署）
kubectl apply -f monitoring/argocd/applicationset.yaml

# 4. 检查 ApplicationSet 状态
kubectl get applicationset -n monitoring

# 5. 查看自动创建的 Application
kubectl get applications -n monitoring

# 6. 验证 Application 状态
kubectl get applications -n monitoring -o wide
```

**说明**：
- ApplicationSet 本身是一个 Kubernetes 资源，需要先部署到集群
- 部署后，ApplicationSet 会自动从 Git 仓库读取 Application 定义并创建 Application 资源
- 后续 Application 的变更会通过 GitOps 自动同步

##### 方式 2：通过 ArgoCD 管理 ApplicationSet（可选，完全 GitOps）

如果想完全通过 GitOps 管理 ApplicationSet，可以创建一个 Application 来管理它：

**`argocd/applicationset-app.yaml`**（在 argocd namespace 创建）

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: applicationset-monitoring-stack
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/leonardsun899/monitoring-stack.git
    targetRevision: main
    path: monitoring/argocd
    directory:
      include: applicationset.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

然后部署：
```bash
kubectl apply -f argocd/applicationset-app.yaml
```

**注意**：这种方式需要先配置 ArgoCD 监控 `monitoring` namespace（方法 1），否则 ApplicationSet 资源无法被创建。

#### ApplicationSet 的优势

- ✅ **自动发现**：从 Git 仓库自动发现 Application 定义
- ✅ **GitOps**：完全符合 GitOps 实践
- ✅ **灵活配置**：可以基于目录、文件、标签等生成 Application
- ✅ **集中管理**：Application 资源可以在目标 namespace
- ✅ **易于扩展**：添加新应用只需在 Git 仓库中添加文件

#### ApplicationSet 的限制

- ⚠️ **需要配置**：需要先配置 ArgoCD 监控目标 namespace（方法 1）
- ⚠️ **模板复杂**：对于多源配置，模板可能较复杂
- ⚠️ **版本要求**：需要 ArgoCD 2.3+ 版本

## 📊 配置对比

| 配置方式 | Application 资源位置 | 应用部署位置 | 是否需要额外配置 | 推荐场景 |
|---------|---------------------|-------------|----------------|---------|
| **当前配置（推荐）** | `argocd` | `monitoring` | ❌ 不需要 | 大多数场景 |
| **方法 1：ConfigMap** | `monitoring` | `monitoring` | ✅ 需要 | 简单场景 |
| **方法 2：ApplicationSet** | `monitoring` | `monitoring` | ✅ 需要 | 复杂场景，GitOps |

## 🎯 建议

### 对于大多数场景

**保持当前配置**：
- Application 资源在 `argocd` namespace
- 应用部署在 `monitoring` namespace
- **无需额外配置即可在 UI 中看到所有应用**

这样既简单又符合最佳实践。

### 如果需要将 Application 资源放到其他 namespace

1. **简单场景**：使用方法 1（ConfigMap）
2. **复杂场景**：使用方法 2（ApplicationSet）

## 📚 参考

- [ArgoCD Application 文档](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#applications)
- [ArgoCD ApplicationSet 文档](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/)
- [ArgoCD 多 namespace 配置](https://argo-cd.readthedocs.io/en/stable/operator-manual/application-controller/#application-namespaces)

