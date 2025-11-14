# DigitalOcean Spaces 配置 - 分步命令行指南

本文档提供**一步步的命令行操作**，用于创建 DigitalOcean Spaces 并配置 Loki。

---

## 📋 前置检查

### 1. 检查 doctl 是否已安装和认证

```bash
# 检查 doctl 版本
doctl version

# 检查认证状态
doctl auth list
```

如果未认证，运行：
```bash
doctl auth init
```

### 2. 检查 Kubernetes 连接

```bash
kubectl cluster-info
kubectl get nodes
```

---

## 🚀 步骤 1: 创建 DigitalOcean Spaces

### 方法 A: 使用 doctl（如果支持）

```bash
# 检查 doctl 是否支持创建 Spaces
doctl spaces create --help
```

如果支持，使用：
```bash
# 创建 Spaces（替换为你的名称和区域）
doctl spaces create loki-storage-sgp1 --region sgp1
```

### 方法 B: 手动创建（推荐）

**注意**：doctl 可能不支持直接创建 Spaces，需要通过控制面板创建。

1. 访问 [DigitalOcean Spaces 控制面板](https://cloud.digitalocean.com/spaces)
2. 点击 **"Create a Space"**
3. 配置：
   - **Name**: `loki-storage-sgp1`（或你喜欢的名称，必须全局唯一）
   - **Region**: `Singapore (sgp1)` - 最接近悉尼
   - **File Listing**: `Restrict File Listing`（推荐）
4. 点击 **"Create a Space"**

### 验证 Spaces 创建

```bash
# 列出所有 Spaces
doctl spaces list

# 或者查看特定 Spaces
doctl spaces list | grep loki-storage
```

**记录以下信息**：
- Spaces 名称: `_________________`
- 区域: `sgp1` (或你选择的区域)

---

## 🔑 步骤 2: 创建访问密钥

### 方法 A: 使用 doctl（如果支持）

```bash
# 检查是否支持创建密钥
doctl spaces keys create --help
```

如果支持：
```bash
doctl spaces keys create loki-spaces-key
```

### 方法 B: 手动创建（推荐）

1. 访问 [DigitalOcean Spaces Keys](https://cloud.digitalocean.com/account/api/spaces)
2. 点击 **"Generate New Key"**
3. 输入名称：`loki-spaces-key`
4. 点击 **"Generate Key"**
5. **重要**：保存以下信息（只显示一次）：
   - **Access Key**: `_________________`
   - **Secret Key**: `_________________`

---

## 🔐 步骤 3: 创建 Kubernetes Secret

```bash
# 替换为你的实际值
ACCESS_KEY="你的 Access Key"
SECRET_KEY="你的 Secret Key"
NAMESPACE="monitoring"
SECRET_NAME="loki-spaces-credentials"

# 创建命名空间（如果不存在）
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# 删除已存在的 Secret（如果存在）
kubectl delete secret $SECRET_NAME -n $NAMESPACE --ignore-not-found=true

# 创建新的 Secret
kubectl create secret generic $SECRET_NAME \
  --from-literal=AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
  --namespace $NAMESPACE

# 验证 Secret
kubectl get secret $SECRET_NAME -n $NAMESPACE
```

---

## ⚙️ 步骤 4: 更新 Loki 配置文件

### 4.1 确定区域端点

根据你的区域，端点格式为：`<region>.digitaloceanspaces.com`

**常见区域端点**：
- `sgp1` → `sgp1.digitaloceanspaces.com`
- `nyc3` → `nyc3.digitaloceanspaces.com`
- `sfo3` → `sfo3.digitaloceanspaces.com`
- `ams3` → `ams3.digitaloceanspaces.com`
- `fra1` → `fra1.digitaloceanspaces.com`

### 4.2 更新配置文件

```bash
# 设置变量（替换为你的实际值）
SPACE_NAME="loki-storage-sgp1"  # 你的 Spaces 名称
REGION="sgp1"                    # 你的区域
ENDPOINT="sgp1.digitaloceanspaces.com"  # 你的端点

# 更新 loki-values-default.yaml
sed -i.bak \
  -e "s/chunks: loki-storage/chunks: $SPACE_NAME/g" \
  -e "s/ruler: loki-storage/ruler: $SPACE_NAME/g" \
  -e "s|endpoint: sgp1.digitaloceanspaces.com|endpoint: $ENDPOINT|g" \
  -e "s/region: sgp1/region: $REGION/g" \
  monitoring/values/loki-values-default.yaml

# 删除备份文件
rm -f monitoring/values/loki-values-default.yaml.bak

# 验证更改
cat monitoring/values/loki-values-default.yaml | grep -A 5 "bucketNames:"
```

---

## 🔄 步骤 5: 更新 ArgoCD Application

```bash
# 更新 ArgoCD Application 使用新的 values 文件
sed -i.bak 's|loki-values.yaml|loki-values-default.yaml|g' monitoring/argocd/loki.yaml

# 删除备份文件
rm -f monitoring/argocd/loki.yaml.bak

# 验证更改
grep "loki-values-default.yaml" monitoring/argocd/loki.yaml
```

---

## 📤 步骤 6: 提交到 Git

```bash
# 查看更改
git status

# 添加更改的文件
git add monitoring/values/loki-values-default.yaml monitoring/argocd/loki.yaml

# 提交
git commit -m "feat: Configure Loki to use DigitalOcean Spaces (sgp1)"

# 推送
git push origin main
```

---

## ✅ 步骤 7: 验证配置

### 7.1 检查 ArgoCD Application

```bash
# 查看 Application 状态
kubectl get application loki -n argocd

# 查看详细信息
kubectl describe application loki -n argocd
```

### 7.2 检查 Loki Pods

```bash
# 等待 ArgoCD 同步（可能需要 1-2 分钟）
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki -w

# 查看 Pod 状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki

# 查看日志
kubectl logs -n monitoring -l app.kubernetes.io/name=loki --tail=50
```

### 7.3 检查 Secret

```bash
kubectl get secret loki-spaces-credentials -n monitoring
```

---

## 📋 完整命令清单（复制粘贴）

```bash
# ============================================
# 步骤 1: 创建 Spaces（手动在控制面板创建）
# ============================================
# 访问: https://cloud.digitalocean.com/spaces
# 创建 Spaces: loki-storage-sgp1, 区域: sgp1

# ============================================
# 步骤 2: 创建访问密钥（手动在控制面板创建）
# ============================================
# 访问: https://cloud.digitalocean.com/account/api/spaces
# 创建密钥: loki-spaces-key
# 保存 Access Key 和 Secret Key

# ============================================
# 步骤 3: 设置变量
# ============================================
SPACE_NAME="loki-storage-sgp1"  # 替换为你的 Spaces 名称
REGION="sgp1"                    # 替换为你的区域
ENDPOINT="sgp1.digitaloceanspaces.com"  # 根据区域调整
ACCESS_KEY="你的 Access Key"     # 替换为你的 Access Key
SECRET_KEY="你的 Secret Key"     # 替换为你的 Secret Key

# ============================================
# 步骤 4: 创建 Kubernetes Secret
# ============================================
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl delete secret loki-spaces-credentials -n monitoring --ignore-not-found=true
kubectl create secret generic loki-spaces-credentials \
  --from-literal=AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
  --namespace monitoring

# ============================================
# 步骤 5: 更新配置文件
# ============================================
sed -i.bak \
  -e "s/chunks: loki-storage/chunks: $SPACE_NAME/g" \
  -e "s/ruler: loki-storage/ruler: $SPACE_NAME/g" \
  -e "s|endpoint: sgp1.digitaloceanspaces.com|endpoint: $ENDPOINT|g" \
  -e "s/region: sgp1/region: $REGION/g" \
  monitoring/values/loki-values-default.yaml
rm -f monitoring/values/loki-values-default.yaml.bak

# ============================================
# 步骤 6: 更新 ArgoCD Application
# ============================================
sed -i.bak 's|loki-values.yaml|loki-values-default.yaml|g' monitoring/argocd/loki.yaml
rm -f monitoring/argocd/loki.yaml.bak

# ============================================
# 步骤 7: 提交到 Git
# ============================================
git add monitoring/values/loki-values-default.yaml monitoring/argocd/loki.yaml
git commit -m "feat: Configure Loki to use DigitalOcean Spaces ($SPACE_NAME)"
git push origin main

# ============================================
# 步骤 8: 验证
# ============================================
kubectl get application loki -n argocd
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki
```

---

## 🔍 故障排查

### 问题 1: Secret 创建失败

```bash
# 检查命名空间是否存在
kubectl get namespace monitoring

# 检查 Secret 内容（不显示值）
kubectl get secret loki-spaces-credentials -n monitoring -o yaml
```

### 问题 2: 配置文件更新失败

```bash
# 手动检查配置文件
cat monitoring/values/loki-values-default.yaml | grep -A 10 "bucketNames:"

# 手动编辑
vi monitoring/values/loki-values-default.yaml
```

### 问题 3: ArgoCD 不同步

```bash
# 强制刷新
kubectl patch application loki -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# 查看同步状态
kubectl get application loki -n argocd -o yaml | grep -A 5 "sync"
```

---

## 📝 配置验证清单

- [ ] Spaces 已创建（名称: `_____________`）
- [ ] 访问密钥已创建并保存
- [ ] Kubernetes Secret 已创建
- [ ] `loki-values-default.yaml` 已更新（Spaces 名称和区域）
- [ ] `loki.yaml` 已更新（使用 `loki-values-default.yaml`）
- [ ] 更改已提交到 Git
- [ ] ArgoCD Application 状态为 `Synced`
- [ ] Loki Pods 正在运行

---

## 🎯 下一步

配置完成后，ArgoCD 会自动同步。等待 1-2 分钟后检查：

```bash
kubectl get application loki -n argocd
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki
```

如果一切正常，Loki 应该使用默认 Helm Chart 配置运行，不再有验证错误！

