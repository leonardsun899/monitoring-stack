# 配置的环境特定性说明

本文档说明哪些配置是**所有云环境通用**的，哪些是**特定环境**的。

---

## ✅ 所有云环境通用（必须设置）

以下配置是 **Loki Helm Chart 的要求**，与云环境无关，**所有环境都必须这样设置**：

### 1. `replicas: 0` 设置

```yaml
# 禁用其他部署模式（必须显式禁用，且 replicas 必须设置为 0）
simpleScalable:
  enabled: false
  replicas: 0  # ✅ 所有环境都需要
read:
  enabled: false
  replicas: 0  # ✅ 所有环境都需要
write:
  enabled: false
  replicas: 0  # ✅ 所有环境都需要
backend:
  enabled: false
  replicas: 0  # ✅ 所有环境都需要
```

**原因**：这是 Loki Helm Chart 的验证逻辑要求，与云环境无关。详见 [LOKI-REPLICAS-EXPLANATION.md](./LOKI-REPLICAS-EXPLANATION.md)

### 2. 部署模式配置

```yaml
deploymentMode: SingleBinary  # ✅ 所有环境通用
singleBinary:
  enabled: true
  replicas: 1
```

### 3. 禁用组件配置

```yaml
chunksCache:
  enabled: false  # ✅ 所有环境通用
resultsCache:
  enabled: false  # ✅ 所有环境通用
gateway:
  enabled: false  # ✅ 所有环境通用
canary:
  enabled: false  # ✅ 所有环境通用
```

### 4. Loki 基础配置

```yaml
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  limits_config:
    retention_period: 720h
    # ... 其他配置
```

---

## 🌐 环境特定配置（需要根据环境修改）

以下配置需要根据**实际的云环境**进行修改：

### 1. `storageClassName`（存储类）

这是**唯一需要根据环境修改**的配置项：

#### DigitalOcean Kubernetes

```yaml
persistence:
  enabled: true
  storageClassName: do-block-storage  # ✅ DigitalOcean 特定
  size: 50Gi
```

#### AWS EKS

```yaml
persistence:
  enabled: true
  storageClassName: gp3  # 或 gp2
  size: 50Gi
```

#### Google GKE

```yaml
persistence:
  enabled: true
  storageClassName: standard  # 或 premium-rwo
  size: 50Gi
```

#### Azure AKS

```yaml
persistence:
  enabled: true
  storageClassName: managed-premium  # 或 managed-standard
  size: 50Gi
```

#### 其他环境

```bash
# 查看可用的存储类
kubectl get storageclass

# 使用输出中的 NAME 作为 storageClassName
```

---

## 📊 配置分类总结

| 配置项 | 类型 | 说明 |
|--------|------|------|
| `deploymentMode: SingleBinary` | ✅ 通用 | 所有环境都需要 |
| `singleBinary.enabled: true` | ✅ 通用 | 所有环境都需要 |
| `simpleScalable.replicas: 0` | ✅ 通用 | 所有环境都需要 |
| `read.replicas: 0` | ✅ 通用 | 所有环境都需要 |
| `write.replicas: 0` | ✅ 通用 | 所有环境都需要 |
| `backend.replicas: 0` | ✅ 通用 | 所有环境都需要 |
| `chunksCache.enabled: false` | ✅ 通用 | 所有环境都需要 |
| `resultsCache.enabled: false` | ✅ 通用 | 所有环境都需要 |
| `gateway.enabled: false` | ✅ 通用 | 所有环境都需要 |
| `canary.enabled: false` | ✅ 通用 | 所有环境都需要 |
| `storageClassName` | 🌐 环境特定 | **需要根据环境修改** |

---

## 🔄 迁移到其他环境

如果要从 DigitalOcean 迁移到其他环境，只需要修改 `storageClassName`：

### 步骤 1: 查看目标环境的存储类

```bash
kubectl get storageclass
```

### 步骤 2: 修改配置文件

**需要修改的文件：**
- `monitoring/values/loki-values.yaml`
- `monitoring/values/prometheus-values.yaml`

**修改内容：**
```yaml
# 将 do-block-storage 替换为目标环境的存储类
storageClassName: <目标环境的存储类名称>
```

### 步骤 3: 提交并同步

```bash
git add monitoring/values/*.yaml
git commit -m "chore: Update storageClassName for <环境名称>"
git push origin main
```

ArgoCD 会自动同步更改。

---

## 💡 为什么 `replicas: 0` 是通用的？

`replicas: 0` 的设置是 **Loki Helm Chart 的验证逻辑要求**，与云环境无关：

1. **Helm Chart 的验证逻辑**：在渲染资源之前检查配置是否冲突
2. **验证逻辑只检查 `replicas`**：不检查 `enabled`，也不关心云环境
3. **默认值问题**：如果不显式设置 `replicas: 0`，Helm 会使用默认值（可能是 1），导致验证失败

**结论**：无论你在哪个云环境（AWS、GCP、Azure、DigitalOcean、本地 Kubernetes），只要使用 Loki Helm Chart 的 SingleBinary 模式，都必须设置 `replicas: 0`。

---

## 📚 参考

- [Loki Helm Chart 文档](https://github.com/grafana/helm-charts/tree/main/charts/loki)
- [Kubernetes StorageClass 文档](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [LOKI-REPLICAS-EXPLANATION.md](./LOKI-REPLICAS-EXPLANATION.md) - 为什么需要 `replicas: 0` 的详细说明

