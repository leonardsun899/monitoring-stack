# Loki 存储选项说明：为什么使用 S3 而不是 EBS？

## 📋 简短回答

**Loki 可以使用 EBS，但取决于部署模式：**
- ✅ **SingleBinary 模式**：可以使用 EBS（文件系统存储）
- ✅ **SimpleScalable 模式**：必须使用 S3（对象存储）

当前配置使用 **SimpleScalable 模式**（Helm Chart 默认模式），所以需要 S3。

---

## 🔍 详细解释

### Loki 的两种部署模式

#### 模式 1：SingleBinary（单实例模式）

**特点：**
- 所有组件运行在单个 Pod 中
- 使用文件系统存储（可以是 EBS）
- 不需要对象存储
- 适合测试和小规模部署

**存储配置：**
```yaml
deploymentMode: SingleBinary
loki:
  storage:
    type: filesystem  # 使用文件系统（EBS）

persistence:
  enabled: true
  storageClassName: gp3  # 使用 EBS
  size: 50Gi
```

**优点：**
- ✅ 不需要 S3，成本更低
- ✅ 配置简单
- ✅ 适合测试环境

**缺点：**
- ⚠️ 单实例，扩展性受限
- ⚠️ 数据存储在单个 EBS 卷上
- ⚠️ 如果 Pod 迁移到其他节点，需要重新挂载 EBS

#### 模式 2：SimpleScalable（可扩展模式）

**特点：**
- 组件分离（frontend、querier、distributor、ingester 等）
- 必须使用对象存储（S3）
- 可以独立扩展各组件
- 适合生产环境

**存储配置：**
```yaml
deploymentMode: SimpleScalable
loki:
  storage:
    type: s3  # 必须使用对象存储
    bucketNames:
      chunks: loki-storage
      ruler: loki-storage
    s3:
      region: us-west-2
      # 使用 IRSA，不需要 accessKeyId 和 secretAccessKey

persistence:
  enabled: true
  storageClassName: gp3  # 只用于索引，不是日志数据
  size: 10Gi
```

**优点：**
- ✅ 更好的可扩展性
- ✅ 数据存储在 S3，更可靠
- ✅ 可以独立扩展各组件
- ✅ 适合生产环境

**缺点：**
- ⚠️ 需要 S3 存储（额外成本）
- ⚠️ 配置稍复杂（需要 IRSA 或访问密钥）

---

## 🤔 为什么 SimpleScalable 模式必须使用 S3？

### 技术原因

1. **组件分离架构**
   - SimpleScalable 模式将 Loki 拆分为多个组件
   - 不同组件可能运行在不同的 Pod 上
   - 需要共享存储来访问日志数据
   - EBS 卷只能挂载到一个节点，无法共享

2. **数据分布**
   - Ingester 组件接收日志并写入存储
   - Querier 组件查询日志数据
   - 它们可能运行在不同的 Pod 上
   - 需要共享存储（S3）来访问相同的数据

3. **扩展性需求**
   - 可以增加 Ingester 副本数来处理更多日志
   - 可以增加 Querier 副本数来处理更多查询
   - 所有副本需要访问相同的数据源
   - S3 提供共享访问能力

### 架构对比

```
SingleBinary 模式（可以使用 EBS）：
┌─────────────────────────────────┐
│  Loki Pod (所有组件在一个 Pod)    │
│  ┌───────────────────────────┐  │
│  │ Ingester + Querier + ...  │  │
│  └───────────────────────────┘  │
│           ↓                      │
│  ┌───────────────────────────┐  │
│  │    EBS Volume (gp3)        │  │
│  │    /loki/data              │  │
│  └───────────────────────────┘  │
└─────────────────────────────────┘

SimpleScalable 模式（必须使用 S3）：
┌─────────────────────────────────┐
│  Ingester Pod 1                 │
│  ┌───────────────────────────┐  │
│  │    Ingester Component     │  │
│  └───────────────────────────┘  │
│           ↓                      │
│  ┌───────────────────────────┐  │
│  │    S3 Bucket              │  │
│  │    (共享存储)              │  │
│  └───────────────────────────┘  │
│           ↑                      │
│  ┌───────────────────────────┐  │
│  │    Querier Pod 1          │  │
│  │    Querier Component      │  │
│  └───────────────────────────┘  │
│  ┌───────────────────────────┐  │
│  │    Querier Pod 2          │  │
│  │    Querier Component      │  │
│  └───────────────────────────┘  │
└─────────────────────────────────┘
```

---

## 💡 如何选择？

### 使用 SingleBinary + EBS（推荐用于测试）

**适用场景：**
- 测试环境
- 小规模部署
- 预算有限
- 不需要高可用性

**配置：**
```yaml
# monitoring/values/loki-values.yaml
deploymentMode: SingleBinary
loki:
  storage:
    type: filesystem
persistence:
  enabled: true
  storageClassName: gp3
  size: 50Gi
```

**ArgoCD Application：**
```yaml
# monitoring/argocd/loki.yaml
valueFiles:
  - $values/monitoring/values/loki-values.yaml  # 使用 SingleBinary 配置
```

### 使用 SimpleScalable + S3（推荐用于生产）

**适用场景：**
- 生产环境
- 需要高可用性
- 需要扩展性
- 有 S3 预算

**配置：**
```yaml
# monitoring/values/loki-values-s3.yaml
deploymentMode: SimpleScalable
loki:
  storage:
    type: s3
    bucketNames:
      chunks: loki-storage
      ruler: loki-storage
    s3:
      region: us-west-2
```

**ArgoCD Application：**
```yaml
# monitoring/argocd/loki.yaml
valueFiles:
  - $values/monitoring/values/loki-values-s3.yaml  # 使用 S3 配置
```

---

## 🔄 当前配置说明

### 为什么当前使用 S3？

1. **使用 Terraform 创建了 S3 存储桶**
   - Terraform 自动创建了 S3 存储桶和 IRSA 配置
   - 配置已经准备好使用 S3

2. **使用 SimpleScalable 模式**
   - 这是 Helm Chart 的默认模式
   - 提供更好的可扩展性和可靠性

3. **生产环境最佳实践**
   - S3 提供更好的数据持久化
   - 支持多 Pod 共享数据
   - 更好的扩展性

### 如果想改用 EBS

如果你想使用 EBS 而不是 S3，需要：

1. **修改 ArgoCD Application：**
   ```yaml
   # monitoring/argocd/loki.yaml
   valueFiles:
     - $values/monitoring/values/loki-values.yaml  # 改为使用 SingleBinary 配置
   ```

2. **确保 values 文件使用 SingleBinary 模式：**
   ```yaml
   # monitoring/values/loki-values.yaml
   deploymentMode: SingleBinary
   loki:
     storage:
       type: filesystem
   ```

3. **不需要 S3 相关配置：**
   - 不需要 Terraform 创建 S3 存储桶
   - 不需要 IRSA 配置
   - 不需要 ServiceAccount

---

## 📊 对比总结

| 特性 | SingleBinary + EBS | SimpleScalable + S3 |
|------|-------------------|---------------------|
| **存储类型** | EBS（文件系统） | S3（对象存储） |
| **成本** | ✅ 较低（只有 EBS） | ⚠️ 较高（EBS + S3） |
| **配置复杂度** | ✅ 简单 | ⚠️ 较复杂（需要 IRSA） |
| **扩展性** | ⚠️ 受限（单实例） | ✅ 好（可扩展各组件） |
| **高可用性** | ⚠️ 较低 | ✅ 较高 |
| **数据持久化** | ⚠️ 依赖单个 EBS 卷 | ✅ S3 更可靠 |
| **适用场景** | 测试、小规模 | 生产、大规模 |

---

## 🎯 推荐方案

### 测试环境
- 使用 **SingleBinary + EBS**
- 配置简单，成本低
- 使用 `loki-values.yaml`

### 生产环境
- 使用 **SimpleScalable + S3**
- 更好的可扩展性和可靠性
- 使用 `loki-values-s3.yaml`（当前配置）

---

## 📚 参考

- [Loki 存储后端文档](https://grafana.com/docs/loki/latest/configuration/storage/)
- [Loki 部署模式文档](https://grafana.com/docs/loki/latest/operations/deployment/)
- [AWS EBS vs S3 对比](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ebs-volumes.html)

---

**总结**：Loki 可以使用 EBS，但只在 SingleBinary 模式下。SimpleScalable 模式必须使用 S3，因为需要多个 Pod 共享数据。当前配置使用 SimpleScalable + S3，适合生产环境。

