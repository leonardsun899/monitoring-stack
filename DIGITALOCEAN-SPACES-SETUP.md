# DigitalOcean Spaces 配置指南

本文档说明如何使用 DigitalOcean Spaces（对象存储）来配置 Loki，这样可以避免 SingleBinary 模式的配置问题。

---

## 📋 概述

### DigitalOcean Spaces 是什么？

- **Spaces** 是 DigitalOcean 提供的 S3 兼容对象存储服务
- 与 AWS S3 API 兼容，可以直接使用 S3 工具和库
- 价格：$5/月起，包含 250 GiB 存储和 1 TiB 出站传输
- 入站带宽免费

### 使用 Spaces 的优势

✅ **可以使用默认 Helm Chart 配置**（SimpleScalable 模式）
✅ **避免 `replicas: 0` 的配置问题**
✅ **更好的可扩展性**
✅ **数据持久化更可靠**

### 使用 Spaces 的劣势

❌ **需要额外成本**（$5/月起）
❌ **需要手动创建 Spaces 和访问密钥**
❌ **配置稍微复杂一些**

---

## 🚀 步骤 1: 创建 DigitalOcean Spaces

### 1.1 登录 DigitalOcean 控制面板

访问 [DigitalOcean 控制面板](https://cloud.digitalocean.com/)

### 1.2 创建 Spaces 存储桶

1. 在左侧菜单中，点击 **"Spaces"**
2. 点击 **"Create a Space"** 按钮
3. 配置参数：
   - **Choose a datacenter region**: 选择与你的 Kubernetes 集群相同的区域（推荐）
   - **Choose a name**: 例如 `loki-storage`（名称必须全局唯一）
   - **Choose a file listing privacy**: 选择 **"Restrict File Listing"**（推荐）
4. 点击 **"Create a Space"**

### 1.3 创建访问密钥

1. 在左侧菜单中，点击 **"API"** → **"Spaces Keys"**
2. 点击 **"Generate New Key"**
3. 输入名称：例如 `loki-access-key`
4. 点击 **"Generate Key"**
5. **重要**：保存以下信息（只显示一次）：
   - **Access Key**（类似：`DO1234567890ABCDEFGH`）
   - **Secret Key**（类似：`abcdefghijklmnopqrstuvwxyz1234567890ABCDEFGHIJ`）

---

## 🔐 步骤 2: 在 Kubernetes 中创建 Secret

### 2.1 创建 Secret

```bash
kubectl create secret generic loki-spaces-credentials \
  --from-literal=AWS_ACCESS_KEY_ID="你的 Access Key" \
  --from-literal=AWS_SECRET_ACCESS_KEY="你的 Secret Key" \
  --namespace monitoring
```

### 2.2 验证 Secret

```bash
kubectl get secret loki-spaces-credentials -n monitoring
```

---

## ⚙️ 步骤 3: 配置 Loki 使用 Spaces

### 3.1 创建新的 Values 文件

创建 `monitoring/values/loki-values-spaces.yaml`：

```yaml
# Loki 配置 - 使用 DigitalOcean Spaces
deploymentMode: SimpleScalable

# SimpleScalable 模式配置
simpleScalable:
  enabled: true
  replicas: 1

# 禁用 SingleBinary 模式
singleBinary:
  enabled: false
  replicas: 0

# Loki 存储配置
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: s3
    bucketNames:
      chunks: loki-storage  # 替换为你的 Spaces 名称
      ruler: loki-storage
    s3:
      endpoint: nyc3.digitaloceanspaces.com  # 替换为你的 Spaces 区域端点
      region: nyc3  # 替换为你的 Spaces 区域
      s3ForcePathStyle: true
      secretAccessKey:
        name: loki-spaces-credentials
        key: AWS_SECRET_ACCESS_KEY
      accessKeyId:
        name: loki-spaces-credentials
        key: AWS_ACCESS_KEY_ID
  limits_config:
    retention_period: 720h
    ingestion_rate_mb: 16
    ingestion_burst_size_mb: 32
    max_query_parallelism: 32
    max_query_series: 500

# 持久化存储（用于索引，不是日志数据）
persistence:
  enabled: true
  storageClassName: do-block-storage
  size: 10Gi  # 索引数据较小，10Gi 足够

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

# 缓存组件（SimpleScalable 模式可以使用）
chunksCache:
  enabled: true
  replicas: 1

resultsCache:
  enabled: true
  replicas: 1

# Gateway（SimpleScalable 模式推荐使用）
gateway:
  enabled: true

# Canary（可选）
canary:
  enabled: false
```

### 3.2 查找你的 Spaces 端点

根据你创建 Spaces 时选择的区域，端点格式为：`<region>.digitaloceanspaces.com`

**常见区域端点：**
- `nyc3.digitaloceanspaces.com` (New York 3)
- `sfo3.digitaloceanspaces.com` (San Francisco 3)
- `sgp1.digitaloceanspaces.com` (Singapore 1)
- `ams3.digitaloceanspaces.com` (Amsterdam 3)
- `fra1.digitaloceanspaces.com` (Frankfurt 1)

你可以在 Spaces 控制面板中查看你的 Spaces 的端点 URL。

---

## 🔄 步骤 4: 更新 ArgoCD Application

### 4.1 修改 ArgoCD Application

修改 `monitoring/argocd/loki.yaml`，使用新的 values 文件：

```yaml
spec:
  sources:
    - repoURL: https://grafana.github.io/helm-charts
      chart: loki
      targetRevision: 6.0.0
      helm:
        valueFiles:
          - $values/monitoring/values/loki-values-spaces.yaml  # 使用 Spaces 配置
    - repoURL: https://github.com/leonardsun899/monitoring-stack.git
      targetRevision: main
      ref: values
```

### 4.2 应用更改

```bash
git add monitoring/argocd/loki.yaml monitoring/values/loki-values-spaces.yaml
git commit -m "feat: Configure Loki to use DigitalOcean Spaces"
git push origin main
```

ArgoCD 会自动同步。

---

## 📊 两种方案对比

| 特性 | SingleBinary (当前) | SimpleScalable + Spaces |
|------|-------------------|------------------------|
| **配置复杂度** | ⚠️ 复杂（需要设置很多 `replicas: 0`） | ✅ 简单（使用默认配置） |
| **验证问题** | ❌ 容易出现验证错误 | ✅ 使用默认配置，无验证问题 |
| **成本** | ✅ 免费（只使用块存储） | ❌ $5/月起（Spaces） |
| **可扩展性** | ⚠️ 单实例，扩展受限 | ✅ 可以独立扩展各组件 |
| **数据持久化** | ⚠️ 依赖块存储 | ✅ 对象存储，更可靠 |
| **维护** | ⚠️ 需要特殊配置 | ✅ 标准配置 |

---

## 💡 推荐方案

### 如果预算允许（$5/月）

**推荐使用 SimpleScalable + Spaces**：
- ✅ 配置简单，使用默认 Helm Chart 配置
- ✅ 避免验证错误
- ✅ 更好的可扩展性和可靠性
- ✅ 数据持久化更安全

### 如果预算有限

**继续使用 SingleBinary 模式**：
- ✅ 免费
- ⚠️ 需要仔细配置所有 `replicas: 0`
- ⚠️ 可能需要清除 ArgoCD 缓存

---

## 🔍 验证 Spaces 配置

### 检查 Loki Pod 状态

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki
```

### 检查 Loki 日志

```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=loki --tail=50
```

### 检查 Spaces 中的数据

在 DigitalOcean 控制面板中：
1. 进入你的 Spaces
2. 查看是否有数据上传（可能需要一些时间）

---

## 🛠️ 故障排查

### 问题 1: 无法连接到 Spaces

**错误信息**：`Access Denied` 或 `InvalidAccessKeyId`

**解决方案**：
1. 检查 Secret 是否正确创建
2. 验证 Access Key 和 Secret Key 是否正确
3. 检查 Spaces 区域端点是否正确

### 问题 2: 存储桶不存在

**错误信息**：`NoSuchBucket`

**解决方案**：
1. 确认 Spaces 名称正确
2. 确认 Spaces 已创建
3. 检查区域是否匹配

### 问题 3: 权限问题

**解决方案**：
1. 确保访问密钥有读写权限
2. 检查 Spaces 的文件列表隐私设置

---

## 📚 参考资源

- [DigitalOcean Spaces 文档](https://docs.digitalocean.com/products/spaces/)
- [Loki S3 存储配置](https://grafana.com/docs/loki/latest/configuration/storage/)
- [DigitalOcean Spaces 定价](https://www.digitalocean.com/pricing/spaces)

---

## 🎯 快速开始

如果你想快速切换到 Spaces 配置：

1. **创建 Spaces 和访问密钥**（按照步骤 1）
2. **创建 Kubernetes Secret**（按照步骤 2）
3. **更新配置文件**（使用我提供的 `loki-values-spaces.yaml`）
4. **更新 ArgoCD Application**（修改 values 文件路径）
5. **提交并推送**（ArgoCD 会自动同步）

**需要我帮你创建完整的配置文件吗？**

