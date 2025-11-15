# 存储需求说明

本文档说明监控栈中各个组件的存储需求，以及 Loki 为什么使用 S3 而不是 EBS。

## 📊 存储需求概览

| 组件 | 存储类型 | 是否需要 S3 | 存储大小 | 说明 |
|------|---------|------------|---------|------|
| **Loki** | 对象存储 (S3) + 块存储 (EBS) | ✅ **是**（SimpleScalable 模式）<br>❌ **否**（SingleBinary 模式） | S3: 按需<br>EBS: 10Gi（SimpleScalable）<br>EBS: 50Gi（SingleBinary） | 详见下方 Loki 详细说明 |
| **Prometheus** | 块存储 (EBS) | ❌ 否 | 100Gi | Metrics 数据存储在 EBS |
| **Grafana** | 块存储 (EBS) | ❌ 否 | 10Gi | 仪表板配置和用户数据存储在 EBS |
| **Promtail** | 无持久化存储 | ❌ 否 | - | 不需要持久化存储 |
| **Alertmanager** | 块存储 (EBS) | ❌ 否 | 默认 | 告警数据存储在 EBS |

---

## 🔍 Loki 存储详细说明

### 为什么 Loki 使用 S3 而不是 EBS？

**简短回答：**
- ✅ **SingleBinary 模式**：可以使用 EBS（文件系统存储）
- ✅ **SimpleScalable 模式**：必须使用 S3（对象存储）

当前配置使用 **SimpleScalable 模式**（Helm Chart 默认模式），所以需要 S3。

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

### 为什么 SimpleScalable 模式必须使用 S3？

#### 技术原因

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

#### 架构对比

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

### Loki 存储配置

**当前配置（SimpleScalable + S3）：**

**存储需求：**
- **对象存储 (S3)**：用于存储日志数据（chunks）
  - 使用 AWS S3 存储桶
  - 通过 IRSA 访问（无需存储访问密钥）
  - 数据量取决于日志保留策略和日志量
- **块存储 (EBS)**：用于存储索引数据
  - 使用 `gp3` StorageClass
  - 大小：10Gi（通常足够）

**配置位置：**
- S3 配置：`monitoring/values/loki-values-s3.yaml`
- EBS 配置：`monitoring/values/loki-values-s3.yaml` 中的 `persistence` 部分
- ArgoCD Application：`monitoring/argocd/loki.yaml`（使用 `loki-values-s3.yaml`）

**Terraform 管理：**
- ✅ S3 存储桶由 Terraform 创建和管理
- ✅ IAM Role 和 ServiceAccount 由 Terraform 创建
- ⚠️ EBS 卷由 Kubernetes PVC 自动创建（Terraform 不直接管理）

**备选配置（SingleBinary + EBS）：**

如果想使用 EBS 而不是 S3：

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
   persistence:
     enabled: true
     storageClassName: gp3
     size: 50Gi
   ```

3. **不需要 S3 相关配置：**
   - 不需要 Terraform 创建 S3 存储桶
   - 不需要 IRSA 配置
   - 不需要 ServiceAccount

### 如何选择？

| 特性 | SingleBinary + EBS | SimpleScalable + S3 |
|------|-------------------|---------------------|
| **存储类型** | EBS（文件系统） | S3（对象存储） |
| **成本** | ✅ 较低（只有 EBS） | ⚠️ 较高（EBS + S3） |
| **配置复杂度** | ✅ 简单 | ⚠️ 较复杂（需要 IRSA） |
| **扩展性** | ⚠️ 受限（单实例） | ✅ 好（可扩展各组件） |
| **高可用性** | ⚠️ 较低 | ✅ 较高 |
| **数据持久化** | ⚠️ 依赖单个 EBS 卷 | ✅ S3 更可靠 |
| **适用场景** | 测试、小规模 | 生产、大规模 |

**推荐方案：**
- **测试环境**：使用 SingleBinary + EBS（`loki-values.yaml`）
- **生产环境**：使用 SimpleScalable + S3（`loki-values-s3.yaml`，当前配置）

---

## 🔍 其他组件存储说明

### Prometheus

**存储需求：**
- **块存储 (EBS)**：用于存储 Metrics 数据
  - 使用 `gp3` StorageClass
  - 大小：100Gi（可根据数据保留期调整）
  - 不需要 S3

**配置位置：**
- `monitoring/values/prometheus-values.yaml` 中的 `prometheusSpec.storageSpec`

**Terraform 管理：**
- ❌ Prometheus 存储由 Kubernetes PVC 自动创建
- ❌ Terraform 不管理 Prometheus 存储

### Grafana

**存储需求：**
- **块存储 (EBS)**：用于存储仪表板配置和用户数据
  - 使用 `gp3` StorageClass
  - 大小：10Gi（通常足够）
  - 不需要 S3

**配置位置：**
- `monitoring/values/prometheus-values.yaml` 中的 `grafana.persistence`

**Terraform 管理：**
- ❌ Grafana 存储由 Kubernetes PVC 自动创建
- ❌ Terraform 不管理 Grafana 存储

### Promtail

**存储需求：**
- **无持久化存储**：Promtail 作为 DaemonSet 运行，不需要持久化存储
  - 日志位置信息存储在内存中
  - 不需要 S3 或 EBS

**配置位置：**
- `monitoring/values/promtail-values.yaml`

**Terraform 管理：**
- ❌ Promtail 不需要存储资源

### Alertmanager

**存储需求：**
- **块存储 (EBS)**：用于存储告警数据
  - 使用默认 StorageClass
  - 大小：由 Helm Chart 默认配置决定
  - 不需要 S3

**配置位置：**
- `monitoring/values/prometheus-values.yaml` 中的 `alertmanager` 部分

**Terraform 管理：**
- ❌ Alertmanager 存储由 Kubernetes PVC 自动创建
- ❌ Terraform 不管理 Alertmanager 存储

---

## 📝 总结

### 需要 S3 的组件

**只有 Loki（如果使用 SimpleScalable 模式）需要 S3：**
- ✅ Loki 使用 S3 存储日志数据
- ✅ Terraform 自动创建 S3 存储桶和 IRSA 配置
- ⚠️ 如果使用 SingleBinary 模式，不需要 S3

### 不需要 S3 的组件

以下组件**不需要 S3**，只使用块存储（EBS）：
- ❌ Prometheus：使用 EBS 存储 Metrics
- ❌ Grafana：使用 EBS 存储配置
- ❌ Promtail：不需要持久化存储
- ❌ Alertmanager：使用 EBS 存储告警数据

### Terraform 管理的存储资源

**Terraform 直接管理：**
- ✅ S3 存储桶（用于 Loki SimpleScalable 模式）
- ✅ IAM Role 和策略（用于 IRSA）
- ✅ Kubernetes ServiceAccount（已配置 IRSA）

**Terraform 不直接管理（由 Kubernetes 自动创建）：**
- ❌ Prometheus EBS 卷（通过 PVC）
- ❌ Grafana EBS 卷（通过 PVC）
- ❌ Alertmanager EBS 卷（通过 PVC）
- ❌ Loki EBS 卷（通过 PVC，用于索引或 SingleBinary 模式）

---

## 🔧 S3 Bucket 删除配置

为了确保在 `terraform destroy` 时可以删除 S3 bucket，Terraform 配置中已设置：

```hcl
resource "aws_s3_bucket" "loki_storage" {
  bucket = local.loki_bucket_name
  
  # 允许在 destroy 时删除非空的 bucket
  force_destroy = true
  
  # ... 其他配置
}
```

**注意事项：**
- `force_destroy = true` 会强制删除 bucket 中的所有对象和版本
- 如果 bucket 中有重要数据，请先备份
- 生命周期规则会自动清理旧数据和版本，有助于减少 destroy 时的删除时间

---

## 📚 参考

- [Loki 存储后端文档](https://grafana.com/docs/loki/latest/configuration/storage/)
- [Loki 部署模式文档](https://grafana.com/docs/loki/latest/operations/deployment/)
- [AWS EBS vs S3 对比](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ebs-volumes.html)
