# 完整监控栈从零安装指南

## 🎯 目标

在空的 EKS 集群中依次安装：

1. ArgoCD
2. 测试应用（Nginx + Prometheus Exporter）
3. 监控栈（Prometheus + Grafana + Loki + Promtail）
4. 配置 Metrics 收集和 Grafana 报表

## 📋 前置条件

- Kubernetes 集群（EKS、GKE、DigitalOcean、或其他）
- `kubectl` 已配置并可以访问集群
- Git 仓库（用于存储配置）
- 了解集群的存储类（StorageClass）名称

### 检查存储类

在开始之前，请检查集群的存储类：

```bash
kubectl get storageclass
```

常见存储类名称：

- AWS EKS: `gp3`, `gp2`
- DigitalOcean: `do-block-storage`
- GKE: `standard`, `premium-rwo`
- 其他: 查看上述命令的输出

**重要：** 在部署前，需要将所有配置文件中的 `storageClassName` 替换为实际环境的存储类名称。

## 🚀 Step 1: 安装 ArgoCD

### 1.1 安装 ArgoCD

```bash
# 创建 argocd namespace
kubectl create namespace argocd

# 安装 ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 等待 ArgoCD 就绪
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
kubectl wait --for=condition=available --timeout=300s deployment/argocd-repo-server -n argocd
kubectl wait --for=condition=available --timeout=300s deployment/argocd-applicationset-controller -n argocd
```

### 1.2 获取 ArgoCD Admin 密码

```bash
# 获取初始 admin 密码
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# 使用 port-forward 访问 ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# 访问 https://localhost:8080 (用户名: admin)
```

### 1.3 配置 ArgoCD CLI（可选）

```bash
# 安装 ArgoCD CLI
brew install argocd  # macOS
# 或从 https://argo-cd.readthedocs.io/en/stable/cli_installation/ 下载

# 登录
argocd login localhost:8080 --insecure
```

---

## 🚀 Step 2: 安装测试应用（Nginx + Prometheus Exporter）

### 2.1 创建测试应用目录结构

```bash
mkdir -p test-app/{argocd,values}
cd test-app
```

### 2.2 创建 ArgoCD Application

**`test-app/argocd/nginx-app.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nginx-test-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources: # 注意：使用 sources（复数）以支持多个仓库源
    - repoURL: https://charts.bitnami.com/bitnami
      chart: nginx
      targetRevision: 15.0.0
      helm:
        valueFiles:
          - $values/test-app/values/nginx-values.yaml
    - repoURL: https://github.com/leonardsun899/monitoring-stack.git # 替换为你的 Git 仓库地址
      targetRevision: main
      ref: values # 标识这个 source 用于提供 values 文件
  destination:
    server: https://kubernetes.default.svc
    namespace: test-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**注意：**

- 必须使用 `sources`（复数）而不是 `source`，因为需要同时引用 Helm Chart 仓库和 Git 仓库
- 第一个 source 是 Helm Chart 仓库
- 第二个 source 是 Git 仓库，用于提供 values 文件
- `ref: values` 告诉 ArgoCD 这个 source 用于 values 文件

### 2.3 创建 Values 文件（包含 Metrics Exporter）

**`test-app/values/nginx-values.yaml`**

```yaml
# Nginx 基础配置
replicaCount: 2
service:
  type: LoadBalancer
  ports:
    http: 80

# 启用 Prometheus Metrics Exporter
metrics:
  enabled: true
  service:
    type: ClusterIP
    port: 9113
  serviceMonitor:
    enabled: true
    namespace: monitoring
    labels:
      release: prometheus
    interval: 30s
    scrapeTimeout: 10s

# 资源限制
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

**注意：** 如果使用 Git 仓库，需要将 values 文件提交到仓库。如果直接使用，可以修改 Application 配置。

### 2.4 部署测试应用

**方式 A：使用 Git 仓库（推荐）**

```bash
# 提交到 Git 仓库
git add test-app/
git commit -m "Add nginx test app with metrics"
git push origin main

# 部署 ArgoCD Application
kubectl apply -f test-app/argocd/nginx-app.yaml
```

**方式 B：直接使用（临时测试）**

修改 `nginx-app.yaml`，移除 `ref: values`，直接使用本地 values：

```yaml
spec:
  source:
    repoURL: https://charts.bitnami.com/bitnami
    chart: nginx
    targetRevision: 15.0.0
    helm:
      values: |
        replicaCount: 2
        service:
          type: LoadBalancer
        metrics:
          enabled: true
          serviceMonitor:
            enabled: true
            namespace: monitoring
            labels:
              release: prometheus
```

### 2.5 验证测试应用

```bash
# 检查 Pod
kubectl get pods -n test-app

# 检查 Service
kubectl get svc -n test-app

# 获取 LoadBalancer 地址
kubectl get svc -n test-app nginx-test-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# 检查 Metrics Exporter
kubectl get svc -n test-app nginx-test-app-metrics
kubectl port-forward -n test-app svc/nginx-test-app-metrics 9113:9113
# 访问 http://localhost:9113/metrics 查看 metrics
```

---

## 🚀 Step 3: 安装监控栈

### 3.1 创建监控目录结构

```bash
mkdir -p monitoring/{argocd,values}
cd monitoring
```

### 3.2 创建 Loki Application

**`monitoring/argocd/loki.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki
  namespace: argocd
  labels:
    app.kubernetes.io/name: loki
    app.kubernetes.io/component: monitoring
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: https://grafana.github.io/helm-charts
      chart: loki
      targetRevision: 6.0.0
      helm:
        valueFiles:
          - $values/monitoring/values/loki-values.yaml
    - repoURL: https://github.com/leonardsun899/monitoring-stack.git # 替换为你的 Git 仓库地址
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  revisionHistoryLimit: 3
```

### 3.3 创建 Promtail Application

**`monitoring/argocd/promtail.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: promtail
  namespace: argocd
  labels:
    app.kubernetes.io/name: promtail
    app.kubernetes.io/component: monitoring
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: https://grafana.github.io/helm-charts
      chart: promtail
      targetRevision: 6.0.0
      helm:
        valueFiles:
          - $values/monitoring/values/promtail-values.yaml
    - repoURL: https://github.com/leonardsun899/monitoring-stack.git # 替换为你的 Git 仓库地址
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  revisionHistoryLimit: 3
```

### 3.4 创建 Prometheus + Grafana Application

**`monitoring/argocd/prometheus.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: prometheus
  namespace: argocd
  labels:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/component: monitoring
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: https://prometheus-community.github.io/helm-charts
      chart: kube-prometheus-stack
      targetRevision: 60.0.0
      helm:
        valueFiles:
          - $values/monitoring/values/prometheus-values.yaml
    - repoURL: https://github.com/leonardsun899/monitoring-stack.git # 替换为你的 Git 仓库地址
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  revisionHistoryLimit: 3
```

### 3.5 创建 Values 文件

**`monitoring/values/loki-values.yaml`**

```yaml
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  limits_config:
    retention_period: 720h
    ingestion_rate_mb: 16
    ingestion_burst_size_mb: 32
    max_query_parallelism: 32
    max_query_series: 500

# 使用单实例模式，不需要对象存储
# 如果使用分布式模式，需要配置对象存储（S3、GCS 等）
# 重要：必须设置 deploymentMode，否则会报错
deploymentMode: SingleBinary
singleBinary:
  replicas: 1
  enabled: true

# 禁用其他部署模式，避免冲突
simpleScalable:
  enabled: false
read:
  enabled: false
write:
  enabled: false
backend:
  enabled: false

persistence:
  enabled: true
  storageClassName: do-block-storage # 根据实际环境修改：AWS EKS 使用 gp3，DigitalOcean 使用 do-block-storage
  size: 50Gi

resources:
  requests:
    cpu: 200m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 2Gi

service:
  type: ClusterIP
  port: 3100
```

**重要提示：**

- `deploymentMode: SingleBinary` 是必需的，告诉 Helm Chart 使用单实例模式
- `singleBinary.enabled: true` 是必需的，否则 Loki 会尝试使用分布式模式，需要对象存储
- 必须显式禁用其他模式（simpleScalable, read, write, backend），否则 Helm Chart 验证会失败
- 如果只设置 `singleBinary.enabled: true` 而不设置 `deploymentMode`，会出现错误："You have more than zero replicas configured for both the single binary and simple scalable targets"
- `storageClassName` 需要根据实际环境修改：
  - AWS EKS: `gp3` 或 `gp2`
  - DigitalOcean: `do-block-storage`
  - GKE: `standard` 或 `premium-rwo`
  - 其他环境：使用 `kubectl get storageclass` 查看可用的存储类

**`monitoring/values/promtail-values.yaml`**

```yaml
config:
  clients:
    - url: http://loki.monitoring.svc:3100/loki/api/v1/push
  server:
    http_listen_port: 3101
    grpc_listen_port: 9096
  positions:
    filename: /tmp/positions.yaml
  scrape_configs:
    - job_name: kubernetes-pods
      kubernetes_sd_configs:
        - role: pod
      relabel_configs:
        - source_labels:
            - __meta_kubernetes_pod_phase
          regex: Running
          action: keep
        - action: labelmap
          regex: __meta_kubernetes_pod_label_(.+)
        - action: replace
          replacement: $1
          separator: /
          source_labels:
            - __meta_kubernetes_namespace
            - __meta_kubernetes_pod_name
          target_label: job
        - action: replace
          source_labels:
            - __meta_kubernetes_namespace
          target_label: namespace
        - action: replace
          source_labels:
            - __meta_kubernetes_pod_name
          target_label: pod
        - action: replace
          source_labels:
            - __meta_kubernetes_pod_container_name
          target_label: container
        - replacement: /var/log/pods/*$1/*.log
          separator: /
          source_labels:
            - __meta_kubernetes_pod_uid
            - __meta_kubernetes_pod_container_name
          target_label: __path__
      pipeline_stages:
        - docker: {}

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

daemonset:
  enabled: true
```

**`monitoring/values/prometheus-values.yaml`**

```yaml
prometheus:
  enabled: true
  prometheusSpec:
    retention: 30d
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: do-block-storage # 根据实际环境修改
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 100Gi
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: 2000m
        memory: 4Gi
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false

grafana:
  enabled: true
  # 不配置 admin 部分，让 Helm chart 使用默认配置
  # admin 配置会导致模板错误，使用 secret 配置即可
  secret:
    admin-user: admin
    admin-password: "admin" # 生产环境请使用强密码，建议使用 Kubernetes Secret 管理工具
  persistence:
    enabled: true
    storageClassName: do-block-storage # 根据实际环境修改
    size: 10Gi
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi
  service:
    type: LoadBalancer # 测试环境使用 LoadBalancer，生产环境建议使用 ClusterIP + ALB
    port: 80
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          access: proxy
          url: http://prometheus-operated.monitoring.svc:9090
          isDefault: true
          editable: true
        - name: Loki
          type: loki
          access: proxy
          url: http://loki.monitoring.svc:3100
          isDefault: false  # 重要：只能有一个数据源是默认的
          editable: true
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
        - name: "default"
          orgId: 1
          folder: ""
          type: file
          disableDeletion: false
          editable: true
          options:
            path: /var/lib/grafana/dashboards/default
  dashboards:
    default:
      kubernetes-cluster-monitoring:
        gnetId: 7249
        revision: 1
        datasource: Prometheus
      node-exporter:
        gnetId: 1860
        revision: 27
        datasource: Prometheus
      nginx-exporter:
        gnetId: 12708
        revision: 1
        datasource: Prometheus
      loki-logs:
        gnetId: 13639
        revision: 1
        datasource: Loki

alertmanager:
  enabled: true

nodeExporter:
  enabled: true

kubeStateMetrics:
  enabled: true

defaultRules:
  create: true
```

### 3.6 部署监控栈（按顺序）

```bash
# 1. 部署 Loki
kubectl apply -f monitoring/argocd/loki.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=loki -n monitoring --timeout=300s

# 2. 部署 Promtail
kubectl apply -f monitoring/argocd/promtail.yaml

# 3. 部署 Prometheus + Grafana
kubectl apply -f monitoring/argocd/prometheus.yaml

# 4. 等待所有组件就绪
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus -n monitoring --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=300s
```

---

## 🔍 Step 4: 验证和测试

### 4.1 检查所有组件状态

```bash
# 检查 ArgoCD
kubectl get pods -n argocd

# 检查测试应用
kubectl get pods,svc -n test-app

# 检查监控栈
kubectl get pods,svc -n monitoring

# 检查 ServiceMonitor
kubectl get servicemonitor -n monitoring
```

### 4.2 访问 Grafana

```bash
# 获取 Grafana LoadBalancer 地址
kubectl get svc -n monitoring prometheus-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# 或使用 port-forward
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# 访问 http://localhost:3000 (用户名: admin, 密码: admin)
```

### 4.3 验证 Metrics 收集

**在 Grafana 中：**

1. 进入 **Explore** → 选择 **Prometheus** 数据源
2. 查询 Nginx metrics：
   ```
   nginx_http_requests_total
   ```
3. 查看 Nginx Exporter 仪表板：
   - 进入 **Dashboards** → **Browse**
   - 找到 **Nginx Exporter** 仪表板

### 4.4 验证日志收集

**在 Grafana 中：**

1. 进入 **Explore** → 选择 **Loki** 数据源
2. 查询 Nginx 日志：
   ```
   {namespace="test-app", pod=~"nginx.*"}
   ```
3. 查看日志内容：
   ```
   {namespace="test-app"} |= "GET"
   ```

### 4.5 生成测试流量

```bash
# 获取 Nginx LoadBalancer 地址
NGINX_LB=$(kubectl get svc -n test-app nginx-test-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# 生成测试流量
for i in {1..100}; do
  curl -s http://$NGINX_LB > /dev/null
  sleep 0.1
done

# 然后在 Grafana 中查看 metrics 和 logs
```

---

## 📊 Step 5: 创建自定义仪表板

### 5.1 在 Grafana 中创建 Nginx 监控仪表板

1. 登录 Grafana
2. 进入 **Dashboards** → **New Dashboard**
3. 添加 Panel，使用以下 PromQL 查询：

**Panel 1: Nginx 请求率**

```
rate(nginx_http_requests_total[5m])
```

**Panel 2: Nginx 活跃连接数**

```
nginx_connections_active
```

**Panel 3: Nginx 错误率**

```
rate(nginx_http_requests_total{status=~"5.."}[5m]) / rate(nginx_http_requests_total[5m]) * 100
```

**Panel 4: Nginx 日志（Logs Panel）**

```
{namespace="test-app", pod=~"nginx.*"}
```

### 5.2 保存仪表板

保存为 "Nginx Test App Monitoring"

---

## 🔧 故障排查

### 常见问题

如果遇到部署问题，请参考 [DEBUG.md](./DEBUG.md) 获取详细的故障排查指南。

### ArgoCD 无法同步

```bash
# 检查 ArgoCD 日志
kubectl logs -n argocd deployment/argocd-repo-server

# 检查 Application 状态
kubectl get application -n argocd
kubectl describe application prometheus -n argocd
```

### Loki 部署失败

如果遇到以下错误：

- "Cannot run scalable targets without an object storage backend"
- "You have more than zero replicas configured for both the single binary and simple scalable targets"

解决方案：

1. 检查 `loki-values.yaml` 中是否设置了 `deploymentMode: SingleBinary`
2. 检查是否启用了 `singleBinary.enabled: true`
3. 检查是否禁用了其他模式（simpleScalable, read, write, backend）
4. 参考 [DEBUG.md](./DEBUG.md) 中的问题 1

### nginx-test-app 找不到 values 文件

如果遇到 "no such file or directory" 错误：

1. 检查 `nginx-app.yaml` 是否使用 `sources`（复数）而不是 `source`
2. 确认 Git 仓库 URL 正确
3. 参考 [DEBUG.md](./DEBUG.md) 中的问题 2

### Grafana Pod 无法启动

如果遇到以下错误：

- "secret not found"
- "nil pointer evaluating interface {}.existingSecret"

解决方案：

1. 检查 `prometheus-values.yaml` 中是否**完全移除了 `admin` 配置部分**（不只是注释）
2. 确保只保留 `secret` 配置部分
3. 即使 `admin:` 配置是空的或注释掉的，也会导致模板错误
4. 如果 Secret 仍未创建，可以手动创建（参考 [DEBUG.md](./DEBUG.md) 中的问题 3）
5. 参考 [DEBUG.md](./DEBUG.md) 中的问题 3

### Grafana 数据源配置错误

如果遇到以下错误：

- "Only one datasource per organization can be marked as default"
- Grafana Pod 处于 CrashLoopBackOff 状态

解决方案：

1. 检查 `prometheus-values.yaml` 中的数据源配置
2. 确保只有一个数据源设置了 `isDefault: true`（通常是 Prometheus）
3. 其他数据源（如 Loki）必须设置 `isDefault: false`
4. 参考 [DEBUG.md](./DEBUG.md) 中的问题 4

### Prometheus 无法抓取 Metrics

```bash
# 检查 ServiceMonitor
kubectl get servicemonitor -n monitoring -o yaml

# 检查 Prometheus Targets
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090
# 访问 http://localhost:9090/targets
```

### Promtail 无法收集日志

```bash
# 检查 Promtail 日志
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail --tail=50

# 检查 Promtail 配置
kubectl get configmap -n monitoring promtail -o yaml
```

---

## 📝 快速命令总结

```bash
# 1. 安装 ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. 获取 ArgoCD 密码
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# 3. 访问 ArgoCD
kubectl port-forward svc/argocd-server -n argocd 8080:443

# 4. 部署测试应用
kubectl apply -f test-app/argocd/nginx-app.yaml

# 5. 部署监控栈（按顺序）
kubectl apply -f monitoring/argocd/loki.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=loki -n monitoring --timeout=300s
kubectl apply -f monitoring/argocd/promtail.yaml
kubectl apply -f monitoring/argocd/prometheus.yaml

# 6. 访问 Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# http://localhost:3000 (admin/admin)
```

---

## 📚 参考资源

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Bitnami Nginx Chart](https://github.com/bitnami/charts/tree/main/bitnami/nginx)
- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Loki](https://github.com/grafana/helm-charts/tree/main/charts/loki)
- [Promtail](https://github.com/grafana/helm-charts/tree/main/charts/promtail)
