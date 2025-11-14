# Grafana 登录指南

## 📋 登录信息

根据配置，Grafana 的默认登录凭据为：

- **用户名**: `admin`
- **密码**: `admin`

**⚠️ 注意**: 这是默认配置，生产环境请务必修改为强密码！

## 🌐 访问方式

### 方式 1: 使用 LoadBalancer（推荐）

如果 Grafana Service 配置为 LoadBalancer 类型，可以直接通过外部 IP 访问：

```bash
# 获取 LoadBalancer 地址
kubectl get svc -n monitoring prometheus-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' && echo
# 或
kubectl get svc -n monitoring prometheus-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' && echo
```

然后在浏览器中访问：
- 如果返回的是 hostname: `http://<hostname>`
- 如果返回的是 IP: `http://<ip>`

**当前 LoadBalancer 地址**: `170.64.245.49`

访问: http://170.64.245.49

### 方式 2: 使用 Port-Forward（临时访问）

如果 LoadBalancer 还未就绪或想本地访问：

```bash
# 在本地终端运行
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
```

然后在浏览器中访问: http://localhost:3000

**注意**: 这个命令会一直运行，按 `Ctrl+C` 停止。

### 方式 3: 使用 Ingress（如果配置了）

如果配置了 Ingress，可以通过 Ingress 域名访问：

```bash
# 查看 Ingress
kubectl get ingress -n monitoring
```

## 🔐 修改密码

首次登录后，Grafana 会提示修改默认密码。建议：

1. 登录后立即修改密码
2. 使用强密码（至少 12 个字符，包含大小写字母、数字和特殊字符）
3. 考虑使用 Kubernetes Secret 管理工具（如 Sealed Secrets、External Secrets）来管理密码

## 🔍 验证 Grafana 是否就绪

在访问前，确保 Grafana Pod 正在运行：

```bash
# 检查 Pod 状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana

# 应该看到类似输出：
# NAME                                 READY   STATUS    RESTARTS   AGE
# prometheus-grafana-xxx               3/3     Running   0          5m
```

如果 Pod 状态不是 `Running`，请检查：

```bash
# 查看 Pod 详细信息
kubectl describe pod -n monitoring -l app.kubernetes.io/name=grafana

# 查看 Pod 日志
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana --tail=50
```

## 🚨 常见问题

### Grafana Pod 无法启动

如果遇到 "secret not found" 错误：

1. 检查 Secret 是否存在：
   ```bash
   kubectl get secret -n monitoring | grep grafana
   ```

2. 如果 Secret 不存在，检查 ArgoCD Application 是否已同步：
   ```bash
   kubectl get application prometheus -n argocd
   ```

3. 手动触发同步：
   ```bash
   kubectl patch application prometheus -n argocd \
     --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
   ```

### 无法访问 LoadBalancer

如果 LoadBalancer 地址无法访问：

1. 检查 Service 状态：
   ```bash
   kubectl get svc -n monitoring prometheus-grafana
   ```

2. 检查防火墙规则（DigitalOcean、AWS 等云平台）

3. 使用 port-forward 作为临时解决方案

### 忘记密码

如果需要重置密码：

1. 删除 Grafana Secret（会使用配置中的默认密码）：
   ```bash
   kubectl delete secret -n monitoring -l app.kubernetes.io/name=grafana
   ```

2. 重启 Grafana Pod：
   ```bash
   kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana
   ```

3. 使用配置中的默认密码登录（admin/admin）

## 📊 首次登录后的配置

登录后，Grafana 应该已经自动配置了：

1. **数据源**:
   - Prometheus: `http://prometheus-operated.monitoring.svc:9090`
   - Loki: `http://loki.monitoring.svc:3100`

2. **仪表板**:
   - Kubernetes Cluster Monitoring
   - Node Exporter
   - Nginx Exporter
   - Loki Logs

如果数据源或仪表板未自动加载，请检查：

```bash
# 检查 Grafana 配置
kubectl get configmap -n monitoring | grep grafana

# 查看 Grafana 日志
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana --tail=100
```

