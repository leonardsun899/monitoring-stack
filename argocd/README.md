# ArgoCD 配置

## 配置 ArgoCD Server 为 LoadBalancer

默认情况下，ArgoCD Server 使用 ClusterIP 类型，只能通过 port-forward 访问。如果需要外部访问，可以将其改为 LoadBalancer。

### 方式 1: 使用 kubectl apply（推荐）

```bash
# 应用 Service 配置
kubectl apply -f argocd/argocd-server-service.yaml
```

### 方式 2: 使用 kubectl patch（临时）

```bash
# 临时修改为 LoadBalancer
kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"LoadBalancer"}}'
```

**注意**: 使用 patch 的方式在 ArgoCD 重新同步时可能会被覆盖。

### 获取 LoadBalancer 地址

```bash
# 获取 LoadBalancer 地址
kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' && echo
# 或
kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' && echo
```

### 访问 ArgoCD UI

1. 使用 LoadBalancer 地址访问：
   - HTTP: `http://<loadbalancer-ip-or-hostname>`
   - HTTPS: `https://<loadbalancer-ip-or-hostname>`

2. 登录信息：
   - 用户名: `admin`
   - 密码: 运行以下命令获取
     ```bash
     kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
     ```

### 安全建议

⚠️ **生产环境建议**:
- 使用 Ingress + TLS 证书而不是直接暴露 LoadBalancer
- 配置 OIDC/SSO 认证
- 使用 NetworkPolicy 限制访问
- 考虑使用 ClusterIP + Ingress Controller（如 ALB、NGINX Ingress）

