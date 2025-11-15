# 存储需求说明

本文档说明监控栈中各个组件的存储需求。

## 📊 存储需求概览

| 组件 | 存储类型 | 是否需要 S3 | 存储大小 | 说明 |
|------|---------|------------|---------|------|
| **Loki** | 对象存储 (S3) + 块存储 (EBS) | ✅ **是** | S3: 按需<br>EBS: 10Gi | 日志数据存储在 S3，索引存储在 EBS |
| **Prometheus** | 块存储 (EBS) | ❌ 否 | 100Gi | Metrics 数据存储在 EBS |
| **Grafana** | 块存储 (EBS) | ❌ 否 | 10Gi | 仪表板配置和用户数据存储在 EBS |
| **Promtail** | 无持久化存储 | ❌ 否 | - | 不需要持久化存储 |
| **Alertmanager** | 块存储 (EBS) | ❌ 否 | 默认 | 告警数据存储在 EBS |

## 🔍 详细说明

### Loki

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

**Terraform 管理：**
- ✅ S3 存储桶由 Terraform 创建和管理
- ✅ IAM Role 和 ServiceAccount 由 Terraform 创建
- ⚠️ EBS 卷由 Kubernetes PVC 自动创建（Terraform 不直接管理）

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

## 📝 总结

### 需要 S3 的组件

**只有 Loki（如果使用 SimpleScalable 模式）需要 S3：**
- ✅ Loki 使用 S3 存储日志数据
- ✅ Terraform 自动创建 S3 存储桶和 IRSA 配置

### 不需要 S3 的组件

以下组件**不需要 S3**，只使用块存储（EBS）：
- ❌ Prometheus：使用 EBS 存储 Metrics
- ❌ Grafana：使用 EBS 存储配置
- ❌ Promtail：不需要持久化存储
- ❌ Alertmanager：使用 EBS 存储告警数据

### Terraform 管理的存储资源

**Terraform 直接管理：**
- ✅ S3 存储桶（用于 Loki）
- ✅ IAM Role 和策略（用于 IRSA）
- ✅ Kubernetes ServiceAccount（已配置 IRSA）

**Terraform 不直接管理（由 Kubernetes 自动创建）：**
- ❌ Prometheus EBS 卷（通过 PVC）
- ❌ Grafana EBS 卷（通过 PVC）
- ❌ Alertmanager EBS 卷（通过 PVC）
- ❌ Loki EBS 卷（通过 PVC，用于索引）

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
- 生命周期规则会自动清理旧数据，有助于减少 destroy 时的删除时间

