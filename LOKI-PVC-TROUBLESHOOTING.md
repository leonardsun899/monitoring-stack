# Loki PVC StorageClass 排错过程

## 问题描述

在部署 Loki 应用（使用 SimpleScalable 模式和 S3 存储）时，发现所有 PVC（PersistentVolumeClaim）都处于 `Pending` 状态，无法绑定到存储卷。

### 错误现象

```bash
$ kubectl get pvc -n monitoring | grep loki
NAME                 STATUS   VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-loki-backend-0  Pending                                      <unset>        2m
data-loki-backend-1  Pending                                      <unset>        2m
data-loki-backend-2  Pending                                      <unset>        2m
data-loki-write-0    Pending                                      <unset>        2m
data-loki-write-1    Pending                                      <unset>        2m
data-loki-write-2    Pending                                      <unset>        2m
```

### 错误原因

1. **StorageClass 不存在**：EKS 集群默认只有 `gp2` StorageClass，没有 `gp3`
2. **PVC 未指定 storageClassName**：StatefulSet 的 `volumeClaimTemplates` 中没有指定 `storageClassName`

## 排错过程

### Step 1: 检查 StorageClass

```bash
$ kubectl get storageclass
NAME   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
gp2    kubernetes.io/aws-ebs   Delete          WaitForFirstConsumer   false                  60m
```

**发现**：只有 `gp2`，没有 `gp3`。

### Step 2: 检查 PVC 详情

```bash
$ kubectl describe pvc -n monitoring data-loki-backend-0
Events:
  Type    Reason         Age                From                         Message
  ----    ------         ----               ----                         -------
  Normal  FailedBinding  12s (x10 over 2m)  persistentvolume-controller  no persistent volumes available for this claim and no storage class is set
```

**发现**：PVC 没有指定 `storageClassName`，且没有可用的存储类。

### Step 3: 检查 Terraform 配置

检查 `terraform/main.tf`，发现**没有创建 StorageClass 的资源**。

### Step 4: 手动创建 StorageClass（临时方案）

```bash
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
```

### Step 5: 更新 Terraform 配置

在 `terraform/main.tf` 中添加 StorageClass 资源：

```hcl
# Create gp3 StorageClass for EBS volumes
# EKS cluster comes with gp2 by default, but we need gp3 for better performance and cost
# This is a cluster-level resource, so it's always created (not dependent on create_kubernetes_resources)
resource "kubernetes_storage_class" "gp3" {
  depends_on = [
    module.eks
  ]

  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type   = "gp3"
    fsType = "ext4"
  }
}
```

### Step 6: 导入现有 StorageClass 到 Terraform

```bash
cd terraform
terraform import kubernetes_storage_class.gp3 gp3
```

### Step 7: 检查 Values 文件配置

检查 `monitoring/values/loki-values-s3.yaml`，发现只有全局的 `persistence` 配置：

```yaml
persistence:
  enabled: true
  storageClassName: gp3
  size: 10Gi
```

**问题**：SimpleScalable 模式下的 `backend` 和 `write` 组件需要单独配置 persistence。

### Step 8: 更新 Values 文件

在 `monitoring/values/loki-values-s3.yaml` 中添加组件级别的 persistence 配置：

```yaml
# Persistent storage (for index, not log data)
# For SimpleScalable mode, need to configure persistence for each component
persistence:
  enabled: true
  storageClassName: gp3
  size: 10Gi

# SimpleScalable mode component persistence configuration
simpleScalable:
  backend:
    persistence:
      enabled: true
      storageClassName: gp3
      size: 10Gi
  write:
    persistence:
      enabled: true
      storageClassName: gp3
      size: 10Gi
```

### Step 9: 推送更改并触发 ArgoCD 同步

```bash
git add monitoring/values/loki-values-s3.yaml
git commit -m "fix: Add persistence storageClassName for SimpleScalable backend and write components"
git push origin main

# 触发 ArgoCD 同步
kubectl annotate application loki -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

### Step 10: 检查 StatefulSet 配置

```bash
$ kubectl get statefulset -n monitoring loki-backend -o yaml | grep -A 10 "volumeClaimTemplates:"
  volumeClaimTemplates:
  - apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      creationTimestamp: null
      name: data
    spec:
      accessModes:
      - ReadWriteOnce
      resources:
        requests:
```

**发现**：StatefulSet 的 `volumeClaimTemplates` 中**仍然没有 `storageClassName`**。

### Step 11: 临时修复方案

由于 Helm Chart 可能没有正确应用配置，使用 `kubectl patch` 手动为 PVC 添加 `storageClassName`：

```bash
kubectl patch pvc -n monitoring -l app.kubernetes.io/name=loki --type='merge' -p '{"spec":{"storageClassName":"gp3"}}'
```

### Step 12: 验证修复

```bash
# 检查 PVC 状态
$ kubectl get pvc -n monitoring | grep loki
NAME                 STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-loki-backend-0  Bound    pvc-xxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx    10Gi       RWO            gp3           5m
data-loki-backend-1  Bound    pvc-yyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy    10Gi       RWO            gp3           5m
data-loki-backend-2  Bound    pvc-zzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz    10Gi       RWO            gp3           5m

# 检查 Pods 状态
$ kubectl get pods -n monitoring -l app.kubernetes.io/name=loki | grep -E "(backend|write)"
NAME              READY   STATUS    RESTARTS   AGE
loki-backend-0     2/2     Running   0          2m
loki-backend-1     2/2     Running   0          2m
loki-backend-2     2/2     Running   0          2m
loki-write-0      1/1     Running   0          2m
loki-write-1      1/1     Running   0          2m
loki-write-2      1/1     Running   0          2m
```

## 根本原因分析

1. **Terraform 配置缺失**：初始 Terraform 配置中没有创建 `gp3` StorageClass
2. **Helm Chart 配置问题**：Loki Helm Chart 在 SimpleScalable 模式下，组件级别的 persistence 配置可能没有正确应用到 StatefulSet 的 `volumeClaimTemplates`
3. **Helm Chart 版本问题**：可能需要检查 Helm Chart 版本和文档，确认正确的配置方式

## 解决方案总结

### 已完成的修复

1. ✅ **创建 StorageClass**：在 Terraform 中添加了 `gp3` StorageClass 资源
2. ✅ **导入到 Terraform**：将手动创建的 StorageClass 导入到 Terraform 状态
3. ✅ **更新 Values 文件**：添加了组件级别的 persistence 配置
4. ✅ **临时修复 PVC**：使用 `kubectl patch` 为现有 PVC 添加 `storageClassName`

### 待解决的问题

1. ⚠️ **Helm Chart 配置问题**：StatefulSet 的 `volumeClaimTemplates` 仍然没有正确应用 `storageClassName`
   - 可能需要检查 Helm Chart 版本
   - 可能需要使用不同的配置路径
   - 或者这是 Helm Chart 的已知问题

### 长期解决方案建议

1. **检查 Helm Chart 文档**：确认 SimpleScalable 模式下 persistence 的正确配置方式
2. **升级 Helm Chart**：如果当前版本有 bug，考虑升级到最新版本
3. **使用 Helm post-renderer**：如果需要，可以使用 Helm post-renderer 来修改生成的 YAML
4. **创建自定义 Helm Chart**：如果问题持续，可以考虑 fork 并修复 Helm Chart

## 相关文件

- `terraform/main.tf`：Terraform 配置（包含 StorageClass 资源）
- `monitoring/values/loki-values-s3.yaml`：Loki Helm values 文件
- `monitoring/argocd/loki.yaml`：ArgoCD Application 定义

## 参考命令

```bash
# 检查 StorageClass
kubectl get storageclass

# 检查 PVC 状态
kubectl get pvc -n monitoring | grep loki

# 检查 PVC 详情
kubectl describe pvc -n monitoring data-loki-backend-0

# 检查 StatefulSet 配置
kubectl get statefulset -n monitoring loki-backend -o yaml | grep -A 10 "volumeClaimTemplates:"

# 手动修复 PVC（临时方案）
kubectl patch pvc -n monitoring -l app.kubernetes.io/name=loki --type='merge' -p '{"spec":{"storageClassName":"gp3"}}'

# 触发 ArgoCD 同步
kubectl annotate application loki -n argocd argocd.argoproj.io/refresh=hard --overwrite

# Terraform 导入 StorageClass
cd terraform
terraform import kubernetes_storage_class.gp3 gp3
```

## 经验教训

1. **提前检查 StorageClass**：在部署需要持久化存储的应用前，先确认集群中有正确的 StorageClass
2. **Terraform 应该管理所有基础设施**：包括 StorageClass 等集群级资源
3. **Helm Chart 配置需要仔细验证**：不同部署模式下的配置路径可能不同
4. **临时修复是必要的**：在找到根本原因前，临时修复可以快速恢复服务

