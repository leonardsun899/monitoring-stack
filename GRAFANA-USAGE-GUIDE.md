# Grafana 使用指南

本指南介绍如何使用 Grafana 查看 Kubernetes 集群的 Metrics 和应用程序的 Logs。

---

## 📋 目录

1. [访问 Grafana](#1-访问-grafana)
2. [查看 Metrics（指标）](#2-查看-metrics指标)
3. [查看 Logs（日志）](#3-查看-logs日志)
4. [导入 Dashboard 模板](#4-导入-dashboard-模板)
5. [常用查询示例](#5-常用查询示例)

---

## 1. 访问 Grafana

### 1.1 获取访问地址

```bash
# 方法 1: 使用 Terraform 输出
cd terraform
terraform output grafana_url

# 方法 2: 直接查询 Service
kubectl get svc -n monitoring prometheus-grafana

# 方法 3: 使用 port-forward（如果 LoadBalancer 不可用）
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# 然后访问 http://localhost:3000
```

### 1.2 登录信息

- **用户名**: `admin`
- **密码**: 从 Secret 获取

```bash
# 获取密码
kubectl get secret -n monitoring prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

**默认密码**（如果使用默认配置）: `admin` 或 `prom-operator`

### 1.3 访问 Grafana

在浏览器中打开 Grafana URL，使用上述用户名和密码登录。

---

## 2. 查看 Metrics（指标）

### 2.1 数据源配置

Grafana 已经自动配置了以下数据源：

- **Prometheus**（默认数据源）
  - URL: `http://prometheus-operated.monitoring.svc:9090`
  - 用于查询 Kubernetes 集群和应用的 Metrics

- **Loki**
  - URL: `http://loki.monitoring.svc:3100`
  - 用于查询应用程序的 Logs

**验证数据源**：
1. 登录 Grafana
2. 进入 **Configuration** → **Data Sources**
3. 确认 Prometheus 和 Loki 数据源都已配置且状态为 **Healthy**

### 2.2 使用 Explore 查询 Metrics

1. 点击左侧菜单的 **Explore** 图标（指南针图标）
2. 在顶部选择 **Prometheus** 数据源
3. 在查询框中输入 PromQL 查询

**常用 PromQL 查询**：

```promql
# 查看所有 Pod 的 CPU 使用率
sum(rate(container_cpu_usage_seconds_total{container!="POD",container!=""}[5m])) by (pod, namespace)

# 查看所有 Pod 的内存使用
sum(container_memory_working_set_bytes{container!="POD",container!=""}) by (pod, namespace)

# 查看节点 CPU 使用率
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# 查看节点内存使用率
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100

# 查看 Pod 数量（按命名空间）
count(kube_pod_info) by (namespace)

# 查看 Service 数量
count(kube_service_info) by (namespace)

# 查看所有运行的 Pod
kube_pod_status_phase{phase="Running"}

# 查看 Pod 重启次数
sum(kube_pod_container_status_restarts_total) by (pod, namespace)
```

### 2.3 预装的 Dashboard

系统已经预装了一些 Dashboard，可以直接使用：

1. 点击左侧菜单的 **Dashboards** → **Browse**
2. 查看以下预装的 Dashboard：

#### 2.3.1 Kubernetes Cluster Monitoring (ID: 7249)

**功能**：
- 集群概览（节点、Pod、Service 数量）
- 节点资源使用（CPU、内存、磁盘、网络）
- Pod 资源使用
- 集群健康状态

**访问路径**：Dashboards → Browse → Kubernetes Cluster Monitoring

#### 2.3.2 Node Exporter (ID: 1860)

**功能**：
- 节点 CPU 使用率
- 节点内存使用率
- 节点磁盘 I/O
- 节点网络流量
- 节点负载

**访问路径**：Dashboards → Browse → Node Exporter

#### 2.3.3 Nginx Exporter (ID: 12708)

**功能**：
- Nginx 请求率
- Nginx 活跃连接数
- Nginx 错误率
- Nginx 响应时间

**访问路径**：Dashboards → Browse → Nginx Exporter

**注意**：需要部署 Nginx Exporter 才能看到数据。

---

## 3. 查看 Logs（日志）

### 3.1 使用 Explore 查询 Logs

1. 点击左侧菜单的 **Explore** 图标
2. 在顶部选择 **Loki** 数据源
3. 在查询框中输入 LogQL 查询

**常用 LogQL 查询**：

```logql
# 查看所有命名空间的日志
{namespace=~".+"}

# 查看特定命名空间的日志
{namespace="monitoring"}

# 查看特定 Pod 的日志
{pod="loki-gateway-64c9b8cc4d-rctp7"}

# 查看包含特定关键词的日志
{namespace="monitoring"} |= "error"

# 查看特定应用的日志（通过 label）
{job="nginx"}

# 查看错误日志
{namespace="monitoring"} |="error" |="Error" |="ERROR"

# 查看特定时间范围的日志
{namespace="monitoring"} [5m]

# 组合查询：查看特定 Pod 的错误日志
{pod=~"loki.*", namespace="monitoring"} |="error"
```

### 3.2 预装的 Loki Dashboard

#### 3.2.1 Loki Logs (ID: 13639)

**功能**：
- 日志搜索和过滤
- 日志时间线
- 日志统计

**访问路径**：Dashboards → Browse → Loki Logs

### 3.3 日志查询技巧

#### 3.3.1 使用标签过滤

Loki 使用标签（Labels）来索引日志，常用的标签包括：

- `namespace`: 命名空间
- `pod`: Pod 名称
- `container`: 容器名称
- `job`: 任务名称（由 Promtail 配置）
- `service_name`: 服务名称

**示例**：

```logql
# 查看 monitoring 命名空间的所有日志
{namespace="monitoring"}

# 查看特定 Pod 的日志
{pod="loki-gateway-64c9b8cc4d-rctp7", namespace="monitoring"}

# 查看多个 Pod 的日志（使用正则）
{pod=~"loki-.*", namespace="monitoring"}
```

#### 3.3.2 使用过滤器

Loki 支持多种过滤器：

- `|= "text"`: 包含文本（大小写敏感）
- `!= "text"`: 不包含文本
- `|~ "regex"`: 匹配正则表达式
- `!~ "regex"`: 不匹配正则表达式

**示例**：

```logql
# 查看包含 "error" 的日志
{namespace="monitoring"} |= "error"

# 查看不包含 "debug" 的日志
{namespace="monitoring"} != "debug"

# 查看匹配正则的日志
{namespace="monitoring"} |~ "error|Error|ERROR"
```

#### 3.3.3 使用时间范围

```logql
# 查看最近 5 分钟的日志
{namespace="monitoring"} [5m]

# 查看最近 1 小时的日志
{namespace="monitoring"} [1h]
```

---

## 4. 导入 Dashboard 模板

### 4.1 从 Grafana.com 导入

Grafana 提供了大量的 Dashboard 模板，可以直接导入使用。

#### 4.1.1 推荐的 Kubernetes Dashboard

1. **Kubernetes Cluster Monitoring** (ID: 7249)
   - 已预装
   - 全面的集群监控

2. **Kubernetes / Compute Resources / Cluster** (ID: 15758)
   - 集群级别的资源监控
   - 导入方法：
     1. Dashboards → Import
     2. 输入 Dashboard ID: `15758`
     3. 选择 Prometheus 数据源
     4. 点击 Import

3. **Kubernetes / Compute Resources / Namespace (Pods)** (ID: 15759)
   - 命名空间和 Pod 级别的资源监控
   - 导入方法同上

4. **Kubernetes / Compute Resources / Pod** (ID: 15760)
   - Pod 级别的详细资源监控
   - 导入方法同上

5. **Kubernetes / Networking / Cluster** (ID: 15761)
   - 集群网络监控
   - 导入方法同上

6. **Kubernetes / Networking / Namespace (Pods)** (ID: 15762)
   - 命名空间网络监控
   - 导入方法同上

#### 4.1.2 导入步骤

1. 登录 Grafana
2. 点击左侧菜单 **Dashboards** → **Import**
3. 在 **Import via grafana.com** 输入框中输入 Dashboard ID
4. 点击 **Load**
5. 选择数据源（通常是 Prometheus）
6. 点击 **Import**

### 4.2 手动创建 Dashboard

#### 4.2.1 创建新的 Dashboard

1. 点击左侧菜单 **Dashboards** → **New Dashboard**
2. 点击 **Add visualization** 或 **Add panel**
3. 选择数据源（Prometheus 或 Loki）
4. 输入查询语句
5. 配置 Panel 类型（Graph、Table、Stat 等）
6. 保存 Dashboard

#### 4.2.2 创建 Pod 监控 Panel

**Panel 1: Pod CPU 使用率**

```promql
sum(rate(container_cpu_usage_seconds_total{container!="POD",container!=""}[5m])) by (pod, namespace)
```

- Panel 类型: Time series
- 单位: Percent (0-100)
- 标题: Pod CPU Usage

**Panel 2: Pod 内存使用**

```promql
sum(container_memory_working_set_bytes{container!="POD",container!=""}) by (pod, namespace)
```

- Panel 类型: Time series
- 单位: bytes (SI)
- 标题: Pod Memory Usage

**Panel 3: Pod 数量（按命名空间）**

```promql
count(kube_pod_info) by (namespace)
```

- Panel 类型: Bar chart
- 标题: Pod Count by Namespace

**Panel 4: Pod 状态**

```promql
count(kube_pod_status_phase) by (phase, namespace)
```

- Panel 类型: Pie chart
- 标题: Pod Status Distribution

#### 4.2.3 创建 Service 监控 Panel

**Panel 1: Service 数量（按命名空间）**

```promql
count(kube_service_info) by (namespace)
```

- Panel 类型: Bar chart
- 标题: Service Count by Namespace

**Panel 2: Service Endpoints**

```promql
kube_endpoint_address_available
```

- Panel 类型: Table
- 标题: Service Endpoints

---

## 5. 常用查询示例

### 5.1 集群级别 Metrics

#### 5.1.1 节点资源

```promql
# 节点 CPU 使用率
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# 节点内存使用率
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100

# 节点磁盘使用率
100 - ((node_filesystem_avail_bytes{mountpoint="/"} * 100) / node_filesystem_size_bytes{mountpoint="/"})

# 节点网络接收速率
rate(node_network_receive_bytes_total[5m])

# 节点网络发送速率
rate(node_network_transmit_bytes_total[5m])
```

#### 5.1.2 集群概览

```promql
# 总节点数
count(node_uname_info)

# 总 Pod 数
count(kube_pod_info)

# 总 Service 数
count(kube_service_info)

# 运行中的 Pod 数
count(kube_pod_status_phase{phase="Running"})

# Pending 的 Pod 数
count(kube_pod_status_phase{phase="Pending"})

# 失败的 Pod 数
count(kube_pod_status_phase{phase="Failed"})
```

### 5.2 Pod 级别 Metrics

```promql
# Pod CPU 使用率（按命名空间）
sum(rate(container_cpu_usage_seconds_total{container!="POD",container!=""}[5m])) by (namespace)

# Pod 内存使用（按命名空间）
sum(container_memory_working_set_bytes{container!="POD",container!=""}) by (namespace)

# Pod 重启次数
sum(kube_pod_container_status_restarts_total) by (pod, namespace)

# Pod 网络接收
sum(rate(container_network_receive_bytes_total[5m])) by (pod, namespace)

# Pod 网络发送
sum(rate(container_network_transmit_bytes_total[5m])) by (pod, namespace)
```

### 5.3 Service 级别 Metrics

```promql
# Service 数量（按命名空间）
count(kube_service_info) by (namespace)

# Service Endpoints 可用性
kube_endpoint_address_available

# Service 类型分布
count(kube_service_info) by (type)
```

### 5.4 应用日志查询

#### 5.4.1 Loki 日志查询

```logql
# 查看所有命名空间的日志
{namespace=~".+"}

# 查看特定应用的日志
{namespace="monitoring", pod=~"loki.*"}

# 查看错误日志
{namespace="monitoring"} |="error" |="Error" |="ERROR"

# 查看特定时间段的日志
{namespace="monitoring"} [1h]

# 查看包含特定关键词的日志
{namespace="monitoring"} |= "failed" |= "timeout"

# 查看特定容器的日志
{namespace="monitoring", container="loki"}

# 统计日志行数（按 Pod）
sum(count_over_time({namespace="monitoring"}[5m])) by (pod)
```

#### 5.4.2 日志分析

```logql
# 查看最近的错误日志
{namespace="monitoring"} |="error" |="Error" |="ERROR" |="fatal" |="FATAL"

# 查看特定 HTTP 状态码的日志
{namespace="test-app"} |~ "status.*(4|5)[0-9]{2}"

# 查看慢查询日志
{namespace="monitoring"} |~ "duration.*[0-9]+s" |~ "slow"

# 查看特定 IP 的访问日志
{namespace="test-app"} |~ "192.168.1.100"
```

### 5.5 组合查询（Metrics + Logs）

在同一个 Dashboard 中可以同时显示 Metrics 和 Logs：

1. 创建 Dashboard
2. 添加 Prometheus Panel（显示 Metrics）
3. 添加 Loki Panel（显示 Logs）
4. 使用相同的标签过滤，确保数据一致

**示例 Dashboard 布局**：

```
┌─────────────────────────────────────┐
│  Dashboard: Application Monitoring   │
├─────────────────────────────────────┤
│  Panel 1: CPU Usage (Prometheus)   │
│  Panel 2: Memory Usage (Prometheus) │
│  Panel 3: Error Logs (Loki)         │
│  Panel 4: Request Logs (Loki)       │
└─────────────────────────────────────┘
```

---

## 6. 最佳实践

### 6.1 Dashboard 组织

- 按功能分组：集群监控、应用监控、日志分析
- 使用文件夹组织 Dashboard
- 为 Dashboard 添加描述和标签

### 6.2 查询优化

- 使用标签过滤减少查询数据量
- 合理设置时间范围
- 使用 `rate()` 和 `increase()` 处理计数器
- 避免过于复杂的查询

### 6.3 告警配置

1. 进入 **Alerting** → **Alert rules**
2. 创建告警规则
3. 配置告警条件（PromQL 查询）
4. 设置通知渠道

**示例告警规则**：

```promql
# Pod CPU 使用率超过 80%
sum(rate(container_cpu_usage_seconds_total{container!="POD",container!=""}[5m])) by (pod, namespace) > 0.8

# Pod 内存使用超过 90%
sum(container_memory_working_set_bytes{container!="POD",container!=""}) by (pod, namespace) / sum(container_spec_memory_limit_bytes{container!="POD",container!=""}) by (pod, namespace) > 0.9

# Pod 重启次数超过 5 次
sum(kube_pod_container_status_restarts_total) by (pod, namespace) > 5
```

---

## 7. 故障排查

### 7.1 数据源连接问题

```bash
# 检查 Prometheus 服务
kubectl get svc -n monitoring prometheus-operated

# 检查 Loki 服务
kubectl get svc -n monitoring loki-gateway

# 测试数据源连接
kubectl exec -n monitoring <grafana-pod> -- wget -qO- http://prometheus-operated.monitoring.svc:9090/api/v1/status/config
```

### 7.2 没有数据

1. 检查时间范围设置
2. 检查标签是否正确
3. 检查 Prometheus/Loki 是否在收集数据
4. 检查 ServiceMonitor/PodMonitor 配置

### 7.3 性能问题

- 减少查询时间范围
- 使用更具体的标签过滤
- 减少 Dashboard 中的 Panel 数量
- 使用 Recording Rules 预计算指标

---

## 8. 快速参考

### 8.1 常用 PromQL 函数

- `rate()`: 计算速率
- `increase()`: 计算增量
- `sum()`: 求和
- `avg()`: 平均值
- `max()`: 最大值
- `min()`: 最小值
- `count()`: 计数
- `by()`: 按标签分组
- `without()`: 排除标签分组

### 8.2 常用 LogQL 操作符

- `|=`: 包含（大小写敏感）
- `!=`: 不包含
- `|~`: 匹配正则
- `!~`: 不匹配正则
- `| json`: 解析 JSON 日志
- `| regexp`: 提取字段
- `| line_format`: 格式化输出

### 8.3 有用的链接

- [Prometheus Query Documentation](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [LogQL Documentation](https://grafana.com/docs/loki/latest/logql/)
- [Grafana Dashboard Templates](https://grafana.com/grafana/dashboards/)
- [PromQL Cheat Sheet](https://promlabs.com/promql-cheat-sheet/)

---

## 9. 示例场景

### 9.1 监控应用性能

**目标**：监控 Nginx 应用的性能和错误

1. **创建 Dashboard**
   - 名称: "Nginx Application Monitoring"

2. **添加 Metrics Panels**
   - CPU 使用率
   - 内存使用
   - 请求率
   - 错误率

3. **添加 Logs Panels**
   - 错误日志
   - 访问日志
   - 慢请求日志

4. **配置告警**
   - CPU > 80%
   - 错误率 > 5%
   - 响应时间 > 1s

### 9.2 排查问题

**场景**：应用响应慢

1. **查看 Metrics**
   - Pod CPU/内存使用
   - 请求率
   - 响应时间

2. **查看 Logs**
   - 错误日志
   - 慢查询日志
   - 超时日志

3. **关联分析**
   - 对比 Metrics 和 Logs 的时间线
   - 找出问题发生的时间点
   - 分析相关日志

---

## 10. 总结

通过 Grafana，你可以：

- ✅ 实时监控 Kubernetes 集群的 Metrics
- ✅ 查看和分析应用程序的 Logs
- ✅ 使用预装的 Dashboard 快速开始
- ✅ 导入社区 Dashboard 模板
- ✅ 创建自定义 Dashboard
- ✅ 配置告警规则

**下一步**：
1. 登录 Grafana 探索预装的 Dashboard
2. 尝试在 Explore 中查询 Metrics 和 Logs
3. 导入推荐的 Kubernetes Dashboard
4. 创建自己的应用监控 Dashboard

---

**需要帮助？** 查看 [DEBUG.md](./DEBUG.md) 获取故障排查指南。

