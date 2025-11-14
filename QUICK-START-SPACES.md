# 快速开始：使用 DigitalOcean Spaces 配置 Loki

## 🎯 概述

使用 Spaces 可以让 Loki 使用**默认 Helm Chart 配置**，避免 SingleBinary 模式的验证问题。

---

## 🚀 快速步骤

### 1. 运行自动化脚本

```bash
./setup-loki-spaces.sh
```

脚本会：
- ✅ 引导你创建 Spaces（或使用 API 自动创建）
- ✅ 创建访问密钥
- ✅ 创建 Kubernetes Secret
- ✅ 更新 Loki 配置文件
- ✅ 更新 ArgoCD Application
- ✅ 提交到 Git

### 2. 脚本会询问的信息

1. **Spaces 名称**：可以直接回车使用默认（带时间戳，确保唯一）
2. **区域**：直接回车使用 `sgp1`（新加坡，最接近悉尼）✅
3. **Access Key**：如果 API 创建失败，需要手动输入
4. **Secret Key**：如果 API 创建失败，需要手动输入

---

## 📋 手动步骤（如果脚本失败）

### 步骤 1: 创建 Spaces

```bash
# 使用 doctl 创建（如果支持）
doctl spaces create loki-storage --region sgp1

# 或者手动在控制面板创建
# 访问: https://cloud.digitalocean.com/spaces
```

### 步骤 2: 创建访问密钥

```bash
# 访问: https://cloud.digitalocean.com/account/api/spaces
# 点击 "Generate New Key"
# 保存 Access Key 和 Secret Key
```

### 步骤 3: 创建 Kubernetes Secret

```bash
kubectl create secret generic loki-spaces-credentials \
  --from-literal=AWS_ACCESS_KEY_ID="你的 Access Key" \
  --from-literal=AWS_SECRET_ACCESS_KEY="你的 Secret Key" \
  --namespace monitoring
```

### 步骤 4: 更新配置文件

脚本会自动更新，或手动修改：
- `monitoring/values/loki-values-default.yaml` - 替换 Spaces 名称和区域
- `monitoring/argocd/loki.yaml` - 使用 `loki-values-default.yaml`

---

## ✅ 配置说明

### 使用的配置

- **文件**: `monitoring/values/loki-values-default.yaml`
- **特点**: 只覆盖必要的 Spaces 配置，其他使用 Helm Chart 默认值
- **模式**: `SimpleScalable`（默认模式）
- **区域**: `sgp1` (Singapore) - 最接近悉尼

### 与 SingleBinary 模式的区别

| 特性 | SingleBinary | SimpleScalable + Spaces |
|------|-------------|------------------------|
| **配置复杂度** | ⚠️ 复杂 | ✅ 简单（默认配置） |
| **验证问题** | ❌ 容易出现 | ✅ 无问题 |
| **成本** | ✅ 免费 | ❌ $5/月 |
| **区域** | 不适用 | ✅ sgp1 (Singapore) |

---

## 🔍 验证

脚本运行完成后：

```bash
# 检查 ArgoCD Application
kubectl get application loki -n argocd

# 检查 Loki Pods
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki

# 查看日志
kubectl logs -n monitoring -l app.kubernetes.io/name=loki --tail=50
```

---

## 📝 注意事项

1. **区域选择**：脚本默认使用 `sgp1`（新加坡），这是最接近悉尼的区域
2. **Spaces 名称**：必须全局唯一，脚本会自动添加时间戳
3. **访问密钥**：只显示一次，请妥善保存
4. **成本**：Spaces 每月 $5 起（250 GiB 存储 + 1 TiB 传输）

---

## 🆘 故障排查

如果脚本失败：

1. **检查 doctl 认证**：`doctl auth list`
2. **检查 Kubernetes 连接**：`kubectl cluster-info`
3. **查看脚本输出**：检查错误信息
4. **手动执行步骤**：参考上面的手动步骤

---

## 📚 相关文档

- [DIGITALOCEAN-SPACES-SETUP.md](./DIGITALOCEAN-SPACES-SETUP.md) - 详细配置指南
- [LOKI-CONFIG-COMPARISON.md](./LOKI-CONFIG-COMPARISON.md) - 配置对比
- [setup-loki-spaces.sh](./setup-loki-spaces.sh) - 自动化脚本

