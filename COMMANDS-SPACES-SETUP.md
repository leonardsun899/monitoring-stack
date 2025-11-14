# DigitalOcean Spaces 配置 - 完整命令行步骤

按照以下步骤**一步步执行命令**，配置 Loki 使用 DigitalOcean Spaces。

---

## 📋 步骤 1: 创建 DigitalOcean Spaces

### 方法：手动在控制面板创建（推荐）

**注意**：doctl 不支持直接创建 Spaces，需要通过控制面板创建。

1. 访问：https://cloud.digitalocean.com/spaces
2. 点击 **"Create a Space"**
3. 配置：
   - **Name**: `loki-storage-sgp1`（必须全局唯一）
   - **Region**: `Singapore (sgp1)` - 最接近悉尼
   - **File Listing**: `Restrict File Listing`
4. 点击 **"Create a Space"**

### 验证 Spaces

```bash
# 列出所有 Spaces（如果 doctl 支持）
doctl spaces list

# 或者直接继续下一步
```

**记录信息**：
- Spaces 名称: `loki-storage-sgp1`
- 区域: `sgp1`

---

## 🔑 步骤 2: 创建访问密钥

### 方法 A: 使用 doctl（推荐）

```bash
# 创建访问密钥（替换 loki-storage-sgp1 为你的 Spaces 名称）
doctl spaces keys create loki-spaces-key \
  --grants "bucket=loki-storage-sgp1;permission=fullaccess"
```

**输出示例**：
```
Access Key: DO1234567890ABCDEFGH
Secret Key: abcdefghijklmnopqrstuvwxyz1234567890ABCDEFGHIJ
```

**重要**：保存 Access Key 和 Secret Key！

### 方法 B: 手动在控制面板创建

1. 访问：https://cloud.digitalocean.com/account/api/spaces
2. 点击 **"Generate New Key"**
3. 输入名称：`loki-spaces-key`
4. 点击 **"Generate Key"**
5. 保存 Access Key 和 Secret Key

---

## 🔐 步骤 3: 设置环境变量

```bash
# 设置变量（替换为你的实际值）
export SPACE_NAME="loki-storage-sgp1"  # 你的 Spaces 名称
export REGION="sgp1"                    # 你的区域
export ENDPOINT="sgp1.digitaloceanspaces.com"  # 区域端点
export ACCESS_KEY="DO1234567890ABCDEFGH"  # 你的 Access Key
export SECRET_KEY="abcdefghijklmnopqrstuvwxyz1234567890ABCDEFGHIJ"  # 你的 Secret Key

# 验证变量
echo "Spaces: $SPACE_NAME"
echo "Region: $REGION"
echo "Endpoint: $ENDPOINT"
echo "Access Key: $ACCESS_KEY"
```

---

## 🔐 步骤 4: 创建 Kubernetes Secret

```bash
# 创建命名空间（如果不存在）
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# 删除已存在的 Secret（如果存在）
kubectl delete secret loki-spaces-credentials -n monitoring --ignore-not-found=true

# 创建新的 Secret
kubectl create secret generic loki-spaces-credentials \
  --from-literal=AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
  --namespace monitoring

# 验证 Secret
kubectl get secret loki-spaces-credentials -n monitoring
```

---

## ⚙️ 步骤 5: 更新 Loki 配置文件

```bash
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
echo "检查配置："
grep -A 5 "bucketNames:" monitoring/values/loki-values-default.yaml
grep "endpoint:" monitoring/values/loki-values-default.yaml
grep "region:" monitoring/values/loki-values-default.yaml
```

---

## 🔄 步骤 6: 更新 ArgoCD Application

```bash
# 更新 ArgoCD Application 使用新的 values 文件
sed -i.bak 's|loki-values.yaml|loki-values-default.yaml|g' monitoring/argocd/loki.yaml

# 删除备份文件
rm -f monitoring/argocd/loki.yaml.bak

# 验证更改
echo "检查 ArgoCD Application："
grep "loki-values-default.yaml" monitoring/argocd/loki.yaml
```

---

## 📤 步骤 7: 提交到 Git

```bash
# 查看更改
git status

# 添加更改的文件
git add monitoring/values/loki-values-default.yaml monitoring/argocd/loki.yaml

# 提交
git commit -m "feat: Configure Loki to use DigitalOcean Spaces ($SPACE_NAME)"

# 推送
git push origin main
```

---

## ✅ 步骤 8: 验证配置

### 8.1 检查 ArgoCD Application

```bash
# 查看 Application 状态
kubectl get application loki -n argocd

# 等待同步（可能需要 1-2 分钟）
# 状态应该从 Unknown/OutOfSync 变为 Synced
```

### 8.2 检查 Loki Pods

```bash
# 查看 Pod 状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki

# 应该看到以下 Pods（SimpleScalable 模式）：
# - loki-gateway-xxx
# - loki-distributor-xxx
# - loki-ingester-xxx
# - loki-querier-xxx
# - loki-chunks-cache-xxx
# - loki-results-cache-xxx
```

### 8.3 查看日志

```bash
# 查看 Gateway 日志
kubectl logs -n monitoring -l app.kubernetes.io/name=loki-gateway --tail=50

# 查看 Ingester 日志
kubectl logs -n monitoring -l app.kubernetes.io/name=loki-ingester --tail=50
```

---

## 📋 完整命令清单（一键复制）

```bash
# ============================================
# 步骤 1: 创建 Spaces（手动在控制面板）
# https://cloud.digitalocean.com/spaces
# ============================================

# ============================================
# 步骤 2: 创建访问密钥
# ============================================
doctl spaces keys create loki-spaces-key \
  --grants "bucket=loki-storage-sgp1;permission=fullaccess"

# ============================================
# 步骤 3: 设置变量（替换为你的实际值）
# ============================================
export SPACE_NAME="loki-storage-sgp1"
export REGION="sgp1"
export ENDPOINT="sgp1.digitaloceanspaces.com"
export ACCESS_KEY="你的 Access Key"
export SECRET_KEY="你的 Secret Key"

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

## 🎯 区域端点对照表

| 区域 | 端点 |
|------|------|
| `sgp1` (Singapore) | `sgp1.digitaloceanspaces.com` ✅ 推荐（最接近悉尼） |
| `nyc3` (New York 3) | `nyc3.digitaloceanspaces.com` |
| `sfo3` (San Francisco 3) | `sfo3.digitaloceanspaces.com` |
| `ams3` (Amsterdam 3) | `ams3.digitaloceanspaces.com` |
| `fra1` (Frankfurt 1) | `fra1.digitaloceanspaces.com` |

---

## 🔍 故障排查

### 问题 1: Secret 创建失败

```bash
# 检查命名空间
kubectl get namespace monitoring

# 检查 Secret
kubectl get secret loki-spaces-credentials -n monitoring -o yaml
```

### 问题 2: 配置文件未更新

```bash
# 手动检查
cat monitoring/values/loki-values-default.yaml | grep -A 5 "bucketNames:"

# 手动编辑
vi monitoring/values/loki-values-default.yaml
```

### 问题 3: ArgoCD 不同步

```bash
# 强制刷新
kubectl patch application loki -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# 查看详细状态
kubectl describe application loki -n argocd
```

---

## ✅ 完成检查清单

- [ ] Spaces 已创建（名称: `_____________`）
- [ ] 访问密钥已创建（使用 `doctl spaces keys create`）
- [ ] 环境变量已设置
- [ ] Kubernetes Secret 已创建
- [ ] `loki-values-default.yaml` 已更新
- [ ] `loki.yaml` 已更新
- [ ] 更改已提交到 Git
- [ ] ArgoCD Application 状态为 `Synced`
- [ ] Loki Pods 正在运行

---

**按照以上步骤执行，Loki 将使用默认 Helm Chart 配置，不再有验证错误！**

