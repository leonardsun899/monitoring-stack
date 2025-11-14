# ArgoCD UI 配置指南

## 📋 前置步骤

1. 访问 ArgoCD UI
   ```bash
   # 获取 ArgoCD 密码
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
   
   # 使用 port-forward 访问 ArgoCD UI
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   # 访问 https://localhost:8080 (用户名: admin)
   ```

## 🔧 在 ArgoCD UI 中配置仓库

### 步骤 1: 添加 Git 仓库

1. 登录 ArgoCD UI
2. 点击左侧菜单 **Settings** → **Repositories**
3. 点击 **Connect Repo** 按钮
4. 填写信息：
   - **Type**: Git
   - **Project Name**: default
   - **Repository URL**: `https://github.com/leonardsun899/monitoring-stack.git`
   - **Username**: `leonardsun899` (如果仓库是公开的，可以留空)
   - **Password**: 你的 GitHub Personal Access Token (如果仓库是公开的，可以留空)
   
   **注意**: 由于你的仓库是公开的，通常不需要认证。但如果后续需要访问私有资源，建议添加认证。

5. 点击 **Connect** 按钮
6. 等待连接状态变为 **Successful** ✓

### 步骤 2: 添加 Helm 仓库（可选，公共仓库通常自动可用）

ArgoCD 通常可以自动访问公共 Helm 仓库，但如果遇到问题，可以手动添加：

#### 添加 Grafana Helm 仓库
1. 点击 **Connect Repo** 按钮
2. 填写信息：
   - **Type**: Helm
   - **Project Name**: default
   - **Repository URL**: `https://grafana.github.io/helm-charts`
   - 其他字段留空（公共仓库不需要认证）
3. 点击 **Connect**

#### 添加 Prometheus Community Helm 仓库
1. 点击 **Connect Repo** 按钮
2. 填写信息：
   - **Type**: Helm
   - **Project Name**: default
   - **Repository URL**: `https://prometheus-community.github.io/helm-charts`
   - 其他字段留空
3. 点击 **Connect**

#### 添加 Bitnami Helm 仓库（用于 Nginx）
1. 点击 **Connect Repo** 按钮
2. 填写信息：
   - **Type**: Helm
   - **Project Name**: default
   - **Repository URL**: `https://charts.bitnami.com/bitnami`
   - 其他字段留空
3. 点击 **Connect**

### 步骤 3: 验证仓库连接

在 **Repositories** 页面，确认所有仓库的状态都是 **Successful** ✓

## 🚀 部署应用

配置好仓库后，可以通过以下方式部署应用：

### 方式 1: 使用 kubectl（推荐）

```bash
# 部署监控栈（按顺序）
kubectl apply -f monitoring/argocd/loki.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=loki -n monitoring --timeout=300s

kubectl apply -f monitoring/argocd/promtail.yaml

kubectl apply -f monitoring/argocd/prometheus.yaml

# 部署测试应用（可选）
kubectl apply -f test-app/argocd/nginx-app.yaml
```

### 方式 2: 通过 ArgoCD UI

1. 点击左侧菜单 **Applications**
2. 点击 **New App** 按钮
3. 填写应用信息：
   - **Application Name**: loki (或其他应用名称)
   - **Project Name**: default
   - **Sync Policy**: 
     - ✅ Automatic sync
     - ✅ Self Heal
     - ✅ Prune Resources
4. 在 **Source** 部分：
   - 选择 **Repository Type**: Git
   - **Repository URL**: `https://github.com/leonardsun899/monitoring-stack.git`
   - **Revision**: `main`
   - **Path**: `monitoring/argocd/loki.yaml`
5. 在 **Destination** 部分：
   - **Cluster URL**: `https://kubernetes.default.svc`
   - **Namespace**: `monitoring`
6. 点击 **Create** 按钮

**注意**: 由于我们使用的是 Application 清单文件，推荐使用方式 1（kubectl apply）。

## 🔍 验证部署

1. 在 ArgoCD UI 的 **Applications** 页面查看应用状态
2. 所有应用应该显示为 **Synced** 和 **Healthy** 状态
3. 如果有错误，点击应用名称查看详细日志

## ⚠️ 常见问题

### 问题 1: Git 仓库连接失败

**解决方案**:
- 如果仓库是私有的，确保添加了正确的 Personal Access Token
- 检查仓库 URL 是否正确
- 确认网络可以访问 GitHub

### 问题 2: Helm 仓库连接失败

**解决方案**:
- 公共 Helm 仓库通常不需要手动添加
- 如果遇到问题，检查网络连接
- 可以尝试在 **Settings** → **Repositories** 中手动添加

### 问题 3: Application 无法同步

**解决方案**:
- 检查 Application YAML 文件中的仓库 URL 是否正确
- 确认 Git 仓库中确实存在这些文件
- 查看 Application 的详细日志和事件

## 📝 快速检查清单

- [ ] ArgoCD UI 可以访问
- [ ] Git 仓库已添加到 ArgoCD（可选，公开仓库通常不需要）
- [ ] Helm 仓库连接正常（公共仓库通常自动可用）
- [ ] 准备部署 Application

