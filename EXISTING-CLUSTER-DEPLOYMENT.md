# 在已有集群上部署监控栈 - 完整指南

## 📋 概述

本文档详细说明在**已有 EKS 集群**（通过 CDK 或其他 IaC 工具创建）上，使用 **ArgoCD** 部署 **Prometheus + Loki + Promtail** 监控栈的完整步骤和注意事项。

**适用场景**：

- ✅ EKS 集群已通过 CDK/CloudFormation/Pulumi 创建
- ✅ ArgoCD 已安装并运行
- ✅ ALB Controller 已安装
- ✅ EBS CSI Driver 已安装
- ✅ 已有其他应用通过 ArgoCD 管理

---

## ⚠️ 重要前提检查

在开始之前，请确认以下信息：

### 1. 集群信息

```bash
# 获取集群名称和区域
aws eks list-clusters --region <your-region>

# 获取集群详细信息
aws eks describe-cluster --name <cluster-name> --region <your-region>

# 检查 OIDC Provider（IRSA 必需）
aws eks describe-cluster --name <cluster-name> --region <your-region> \
  --query 'cluster.identity.oidc.issuer' --output text
```

**需要记录的信息**：

- 集群名称：`<cluster-name>`
- AWS 区域：`<region>`（如 `ap-southeast-2`）
- OIDC Provider URL：`https://oidc.eks.<region>.amazonaws.com/id/<id>`

### 2. 访问权限

```bash
# 检查 kubectl 访问
kubectl cluster-info

# 检查 AWS 权限
aws sts get-caller-identity

# 检查集群访问
kubectl get nodes
```

### 3. ArgoCD 状态

```bash
# 检查 ArgoCD 是否运行
kubectl get pods -n argocd

# 检查 ArgoCD 服务
kubectl get svc -n argocd

# 获取 ArgoCD 访问地址
kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

### 4. Git 仓库访问

确保 ArgoCD 可以访问你的 Git 仓库：

```bash
# 在 ArgoCD UI 中检查
# Settings → Repositories → 确认仓库已连接
```

---

## 🔍 关键资源检查清单

在部署前，必须检查以下资源的状态：

### 1. EBS CSI Driver（必须已安装）

**检查方法**：

```bash
# 方法 1: 检查 EKS Add-on
aws eks describe-addon \
  --cluster-name <cluster-name> \
  --addon-name aws-ebs-csi-driver \
  --region <region> \
  --query 'addon.status' --output text

# 方法 2: 检查 Pod
kubectl get pods -n kube-system | grep ebs-csi

# 应该看到：
# ebs-csi-controller-xxx    Running
# ebs-csi-node-xxx          Running
```

**如果未安装**：

```bash
# 安装 EBS CSI Driver（使用 EKS Add-on，推荐）
aws eks create-addon \
  --cluster-name <cluster-name> \
  --addon-name aws-ebs-csi-driver \
  --addon-version v1.32.0-eksbuild.1 \
  --region <region>

# 或使用 Helm
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system
```

**重要**：如果 CSI Driver 已存在，**不需要**通过 Terraform 创建。

### 2. StorageClass gp3（必须存在）

**检查方法**：

```bash
# 检查 StorageClass
kubectl get storageclass gp3

# 检查配置
kubectl get storageclass gp3 -o yaml
```

**必须的配置**：

```yaml
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
volumeBindingMode: WaitForFirstConsumer # 推荐
```

**如果不存在或配置错误**：

```bash
# 创建 gp3 StorageClass
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

**重要**：确保 StorageClass 的 `provisioner` 是 `ebs.csi.aws.com`，否则 PVC 无法绑定。

### 3. OIDC Provider（IRSA 必需）

**检查方法**：

```bash
# 获取 OIDC Provider URL
OIDC_URL=$(aws eks describe-cluster --name <cluster-name> --region <region> \
  --query 'cluster.identity.oidc.issuer' --output text | sed 's|https://||')

# 检查 OIDC Provider 是否已关联到 IAM
aws iam list-open-id-connect-providers | grep $OIDC_URL
```

**如果未关联**：

```bash
# 关联 OIDC Provider
eksctl utils associate-iam-oidc-provider \
  --cluster <cluster-name> \
  --region <region> \
  --approve
```

### 4. 节点资源

**检查方法**：

```bash
# 检查节点数量和资源
kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory

# 检查节点资源使用
kubectl top nodes 2>/dev/null || echo "Metrics server not available"
```

**建议**：

- 至少 2 个节点
- 每个节点至少 2 CPU、4GB 内存
- 对于生产环境，建议 4 个节点或更多

---

## 🚀 完整部署步骤

### Step 0: 准备工作

#### 0.1 克隆或准备代码仓库

```bash
# 如果使用 Git 仓库
git clone <your-repo-url>
cd monitoring-stack

# 或确保代码已提交到 Git 仓库（ArgoCD 需要访问）
```

#### 0.2 配置 kubectl

```bash
# 配置 kubectl 连接到集群
aws eks update-kubeconfig --name <cluster-name> --region <region>

# 验证连接
kubectl cluster-info
kubectl get nodes
```

#### 0.3 检查 ArgoCD Git 仓库配置

在 ArgoCD UI 中：

1. 进入 **Settings** → **Repositories**
2. 确认你的 Git 仓库已添加
3. 如果使用私有仓库，确保认证信息正确

---

### Step 1: 创建 AWS 资源（S3 + IAM）

由于集群已存在，我们只需要创建监控栈所需的 AWS 资源：

- S3 Bucket（用于 Loki 存储）
- IAM Role 和 Policy（用于 IRSA）

#### 1.1 使用 AWS CDK TypeScript 创建资源（推荐）

**创建 CDK 项目结构**：

```bash
# 创建 CDK 项目目录
mkdir -p cdk-monitoring-stack
cd cdk-monitoring-stack

# 初始化 CDK TypeScript 项目
cdk init app --language typescript

# 安装必要的依赖（CDK v2 使用 aws-cdk-lib）
npm install aws-cdk-lib constructs
```

**创建 CDK Stack** (`lib/cdk-monitoring-stack-stack.ts`)：

```typescript
import * as cdk from "aws-cdk-lib";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as iam from "aws-cdk-lib/aws-iam";
import { Construct } from "constructs";

export interface MonitoringStackProps extends cdk.StackProps {
  clusterName: string;
  oidcProviderArn: string;
  oidcIssuerUrl: string;
  retentionDays?: number;
}

export class MonitoringStackStack extends cdk.Stack {
  public readonly lokiBucket: s3.Bucket;
  public readonly lokiRole: iam.Role;

  constructor(scope: Construct, id: string, props: MonitoringStackProps) {
    super(scope, id, props);

    const {
      clusterName,
      oidcProviderArn,
      oidcIssuerUrl,
      retentionDays = 30,
    } = props;

    // 1. 创建 S3 Bucket for Loki
    this.lokiBucket = new s3.Bucket(this, "LokiStorageBucket", {
      bucketName: `${clusterName}-loki-storage-${this.account.substring(0, 8)}`,
      versioned: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      removalPolicy: cdk.RemovalPolicy.DESTROY, // 允许删除非空 bucket
      autoDeleteObjects: true, // 自动删除对象
      lifecycleRules: [
        {
          id: "delete-old-logs",
          enabled: true,
          expiration: cdk.Duration.days(retentionDays),
          noncurrentVersionExpiration: cdk.Duration.days(retentionDays),
        },
      ],
    });

    // 2. 创建 IAM Policy for S3 access
    const lokiS3Policy = new iam.Policy(this, "LokiS3AccessPolicy", {
      policyName: `${clusterName}-loki-s3-access-policy`,
      statements: [
        new iam.PolicyStatement({
          effect: iam.Effect.ALLOW,
          actions: [
            "s3:PutObject",
            "s3:GetObject",
            "s3:DeleteObject",
            "s3:ListBucket",
          ],
          resources: [
            this.lokiBucket.bucketArn,
            `${this.lokiBucket.bucketArn}/*`,
          ],
        }),
      ],
    });

    // 3. 创建 IAM Role for IRSA
    const oidcProvider = iam.OpenIdConnectProvider.fromOpenIdConnectProviderArn(
      this,
      "OidcProvider",
      oidcProviderArn
    );

    const oidcIssuer = oidcIssuerUrl.replace("https://", "");

    this.lokiRole = new iam.Role(this, "LokiS3Role", {
      roleName: `${clusterName}-loki-s3-role`,
      assumedBy: new iam.WebIdentityPrincipal(
        oidcProvider.openIdConnectProviderArn,
        {
          StringEquals: {
            [`${oidcIssuer}:sub`]:
              "system:serviceaccount:monitoring:loki-s3-service-account",
            [`${oidcIssuer}:aud`]: "sts.amazonaws.com",
          },
        }
      ),
    });

    // 4. 附加策略到角色
    this.lokiRole.attachInlinePolicy(lokiS3Policy);

    // 5. 输出值
    new cdk.CfnOutput(this, "LokiBucketName", {
      value: this.lokiBucket.bucketName,
      exportName: `${clusterName}-loki-bucket-name`,
    });

    new cdk.CfnOutput(this, "LokiRoleArn", {
      value: this.lokiRole.roleArn,
      exportName: `${clusterName}-loki-role-arn`,
    });

    new cdk.CfnOutput(this, "AwsRegion", {
      value: this.region,
      exportName: `${clusterName}-aws-region`,
    });
  }
}
```

**更新 CDK App** (`bin/cdk-monitoring-stack.ts`)：

```typescript
#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { MonitoringStackStack } from "../lib/cdk-monitoring-stack-stack";

const app = new cdk.App();

// 从环境变量或配置文件获取集群信息
const clusterName = process.env.CLUSTER_NAME || "your-cluster-name";
const oidcProviderArn =
  process.env.OIDC_PROVIDER_ARN ||
  "arn:aws:iam::ACCOUNT:oidc-provider/oidc.eks.REGION.amazonaws.com/id/ID";
const oidcIssuerUrl =
  process.env.OIDC_ISSUER_URL || "https://oidc.eks.REGION.amazonaws.com/id/ID";
const retentionDays = parseInt(process.env.RETENTION_DAYS || "30");

new MonitoringStackStack(app, "MonitoringStackStack", {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION || "ap-southeast-2",
  },
  clusterName,
  oidcProviderArn,
  oidcIssuerUrl,
  retentionDays,
});
```

**创建配置文件** (`.env.example`)：

```bash
# 集群信息
CLUSTER_NAME=your-cluster-name
CDK_DEFAULT_REGION=ap-southeast-2
CDK_DEFAULT_ACCOUNT=123456789012

# OIDC Provider 信息（从集群获取）
OIDC_PROVIDER_ARN=arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-southeast-2.amazonaws.com/id/ABCDEFGHIJKLMNOP
OIDC_ISSUER_URL=https://oidc.eks.ap-southeast-2.amazonaws.com/id/ABCDEFGHIJKLMNOP

# Loki 配置
RETENTION_DAYS=30
```

#### 1.2 部署 CDK Stack

```bash
# 1. 获取 OIDC Provider 信息
export CLUSTER_NAME="<your-cluster-name>"
export AWS_REGION="<your-region>"

# 获取 OIDC Issuer URL
export OIDC_ISSUER_URL=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --query 'cluster.identity.oidc.issuer' \
  --output text)

# 获取 OIDC Provider ARN
export OIDC_PROVIDER_ARN=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Url, '$(echo $OIDC_ISSUER_URL | sed 's|https://||')')].Arn" \
  --output text)

# 2. 设置环境变量
export CDK_DEFAULT_REGION=$AWS_REGION
export CDK_DEFAULT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# 3. 构建和部署
cd cdk-monitoring-stack
npm install
npm run build
cdk synth
cdk deploy --require-approval never

# 4. 获取输出值
export BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name MonitoringStackStack \
  --query 'Stacks[0].Outputs[?OutputKey==`LokiBucketName`].OutputValue' \
  --output text)

export ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name MonitoringStackStack \
  --query 'Stacks[0].Outputs[?OutputKey==`LokiRoleArn`].OutputValue' \
  --output text)

echo "S3 Bucket: $BUCKET_NAME"
echo "IAM Role ARN: $ROLE_ARN"
echo "AWS Region: $AWS_REGION"
```

#### 1.3 记录输出值

```bash
# 保存输出值供后续使用
cat > .env <<EOF
BUCKET_NAME=$BUCKET_NAME
ROLE_ARN=$ROLE_ARN
AWS_REGION=$AWS_REGION
EOF

source .env
```

**选项 B：手动创建 AWS 资源（如果不想使用 CDK）**

如果不想使用 CDK，可以手动创建（参考原文档中的手动创建步骤）。

---

### Step 2: 创建 Kubernetes 资源

#### 2.1 创建 Namespace（可选，ArgoCD 可以自动创建）

```bash
# 创建 monitoring namespace（如果不存在）
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
```

**注意**：如果 ArgoCD Application 配置了 `CreateNamespace=true`，可以跳过此步骤。

#### 2.2 创建 ServiceAccount 并配置 IRSA

```bash
# 创建 ServiceAccount
kubectl create serviceaccount loki-s3-service-account -n monitoring

# 配置 IRSA 注解（使用 Step 1.3 中获取的 ROLE_ARN）
kubectl annotate serviceaccount loki-s3-service-account -n monitoring \
  eks.amazonaws.com/role-arn=${ROLE_ARN} --overwrite

# 验证
kubectl get serviceaccount loki-s3-service-account -n monitoring -o yaml
```

**重要**：

- ServiceAccount 名称必须是 `loki-s3-service-account`
- Namespace 必须是 `monitoring`
- IAM Role ARN 必须正确

---

### Step 3: 更新 Values 文件配置

#### 3.1 更新 Loki Values 文件

编辑 `monitoring/values/loki-values-s3.yaml`，使用从 Step 1.3 获取的值：

```yaml
# Loki configuration - Using default SimpleScalable mode (requires S3)
# Use default SimpleScalable mode
deploymentMode: SimpleScalable

# Loki storage configuration - AWS S3
loki:
  auth_enabled: false
  # Schema configuration (required for SimpleScalable mode)
  # Loki 3.0.0 requires schema v13 and tsdb index type
  schemaConfig:
    configs:
      - from: "2020-10-24"
        store: tsdb # 必须
        object_store: s3
        schema: v13 # 必须
        index:
          prefix: index_
          period: 24h
  # Disable structured metadata to avoid validation errors
  limits_config:
    allow_structured_metadata: false
  storage:
    type: s3
    bucketNames:
      chunks: <BUCKET_NAME> # 从 Step 1.3 获取，例如: eks-test-loki-storage-565c7d68
      ruler: <BUCKET_NAME> # 从 Step 1.3 获取
    s3:
      endpoint: s3.amazonaws.com
      region: <AWS_REGION> # 从 Step 1.3 获取，例如: ap-southeast-2
      s3ForcePathStyle: false
      # IRSA 会自动处理认证，无需配置 accessKeyId 和 secretAccessKey

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
      # 必须配置 volumeClaimTemplate，确保 StatefulSet 使用正确的 StorageClass
      volumeClaimTemplate:
        spec:
          storageClassName: gp3
  write:
    persistence:
      enabled: true
      storageClassName: gp3
      size: 10Gi
      # 必须配置 volumeClaimTemplate
      volumeClaimTemplate:
        spec:
          storageClassName: gp3

# ServiceAccount configuration (if using IRSA)
serviceAccount:
  create: false # 不自动创建，使用手动创建的（Step 2.2）
  name: loki-s3-service-account # 必须与 Step 2.2 中的名称一致

# Cache components configuration
# Reduce resource requests to fit within node capacity
chunksCache:
  enabled: true
  # Reduce Memcached allocated memory from default 8192MB to 1024MB (1GB)
  # This should match the Kubernetes memory limits
  allocatedMemory: 1024 # MB, reduced from default 8192MB
  maxItemMemory: 5 # MB, maximum item size
  connectionLimit: 16384
  resources:
    requests:
      cpu: 500m
      memory: 1Gi # Reduced from default 9830Mi to fit node capacity (~3.8GB)
    limits:
      memory: 2Gi # Allow some burst but limit to prevent OOM

resultsCache:
  enabled: true
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      memory: 1Gi
```

**使用脚本自动更新**：

```bash
# 如果使用 CDK
cd cdk-monitoring-stack
source .env

# 更新 loki-values-s3.yaml
sed -i.bak \
  -e "s|chunks:.*|chunks: ${BUCKET_NAME}|g" \
  -e "s|ruler:.*|ruler: ${BUCKET_NAME}|g" \
  -e "s|region:.*|region: ${AWS_REGION}|g" \
  ../monitoring/values/loki-values-s3.yaml
```

#### 3.2 Prometheus Values 文件配置

确保 `monitoring/values/prometheus-values.yaml` 配置正确：

```yaml
# Prometheus configuration
prometheus:
  enabled: true
  prometheusSpec:
    retention: 30d
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3 # 必须
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 100Gi
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false

# Grafana configuration
grafana:
  enabled: true
  # Use secret to configure admin account
  secret:
    admin-user: admin
    admin-password: "admin" # 生产环境请使用强密码
  persistence:
    enabled: true
    storageClassName: gp3 # 必须
    size: 10Gi
  service:
    type: ClusterIP # 使用 ClusterIP，LoadBalancer 由其他方式管理
  # 重要：使用 additionalDataSources 而不是 datasources
  # kube-prometheus-stack 会自动创建 Prometheus 数据源
  additionalDataSources:
    - name: Loki
      type: loki
      access: proxy
      url: http://loki.monitoring.svc:3100
      isDefault: false # Prometheus 已由 kube-prometheus-stack 设置为默认
      editable: true
  # Pre-installed dashboards
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

# Enable other components
alertmanager:
  enabled: true
nodeExporter:
  enabled: true
kubeStateMetrics:
  enabled: true
defaultRules:
  create: true
```

#### 3.3 Promtail Values 文件配置

确保 `monitoring/values/promtail-values.yaml` 配置正确：

```yaml
# Promtail configuration
# Configure Promtail to connect to Loki
config:
  clients:
    - url: http://loki.monitoring.svc:3100/loki/api/v1/push
```

#### 3.4 提交更改到 Git

```bash
# 提交更新的 values 文件
git add monitoring/values/loki-values-s3.yaml
git add monitoring/values/prometheus-values.yaml
git add monitoring/values/promtail-values.yaml
git commit -m "chore: Update monitoring stack values files for existing cluster"
git push origin main
```

**重要**：ArgoCD 会从 Git 仓库读取配置，必须提交更改。

---

### Step 4: 验证 ArgoCD 配置

#### 4.1 检查 ArgoCD Application 配置

确保以下文件配置正确：

**`monitoring/argocd/prometheus.yaml`**：

```yaml
spec:
  sources: # 注意：使用 sources（复数）
    - repoURL: https://prometheus-community.github.io/helm-charts
      chart: kube-prometheus-stack
      targetRevision: 60.0.0
      helm:
        valueFiles:
          - $values/monitoring/values/prometheus-values.yaml
    - repoURL: https://github.com/<your-org>/<your-repo>.git # 你的 Git 仓库
      targetRevision: main
      ref: values # 标识这是 values 文件的来源
```

**`monitoring/argocd/loki.yaml`**：

```yaml
spec:
  sources: # 注意：使用 sources（复数）
    - repoURL: https://grafana.github.io/helm-charts
      chart: loki
      targetRevision: 6.0.0
      helm:
        valueFiles:
          - $values/monitoring/values/loki-values-s3.yaml
    - repoURL: https://github.com/<your-org>/<your-repo>.git # 你的 Git 仓库
      targetRevision: main
      ref: values
```

**`monitoring/argocd/promtail.yaml`**：

```yaml
spec:
  sources: # 注意：使用 sources（复数）
    - repoURL: https://grafana.github.io/helm-charts
      chart: promtail
      targetRevision: 6.0.0
      helm:
        valueFiles:
          - $values/monitoring/values/promtail-values.yaml
    - repoURL: https://github.com/<your-org>/<your-repo>.git # 你的 Git 仓库
      targetRevision: main
      ref: values
```

**关键点**：

- ✅ 使用 `sources`（复数）而不是 `source`
- ✅ 第一个 source 是 Helm Chart 仓库
- ✅ 第二个 source 是 Git 仓库，用于提供 values 文件
- ✅ `ref: values` 标识 Git 仓库用于 values 文件

#### 4.2 验证 Git 仓库 URL

确保所有 Application 文件中的 Git 仓库 URL 正确：

```bash
# 检查 Git 仓库 URL
grep -r "repoURL.*github.com" monitoring/argocd/

# 应该显示你的 Git 仓库 URL
```

---

### Step 5: 部署应用（按顺序）

#### 5.1 部署 Loki（第一步）

```bash
# 应用 Loki Application
kubectl apply -f monitoring/argocd/loki.yaml

# 等待 ArgoCD 同步
kubectl wait --for=condition=Synced application/loki -n argocd --timeout=300s

# 检查 Application 状态
kubectl get application loki -n argocd

# 检查 Pod 状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki -w
```

**预期结果**：

- Application 状态：`Synced`、`Healthy`
- Loki Pods 应该处于 `Running` 状态
- 可能需要几分钟时间

**常见问题**：

- 如果 Pod 处于 `Pending`，检查 PVC 是否绑定
- 如果 Pod 处于 `CrashLoopBackOff`，检查日志

#### 5.2 部署 Promtail（第二步）

```bash
# 应用 Promtail Application
kubectl apply -f monitoring/argocd/promtail.yaml

# 等待同步
kubectl wait --for=condition=Synced application/promtail -n argocd --timeout=300s

# 检查状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail
```

#### 5.3 部署 Prometheus（第三步）

```bash
# 应用 Prometheus Application
kubectl apply -f monitoring/argocd/prometheus.yaml

# 等待同步
kubectl wait --for=condition=Synced application/prometheus -n argocd --timeout=300s

# 检查状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana
```

---

### Step 6: 验证部署

#### 6.1 检查所有 Pod 状态

```bash
# 检查所有监控相关的 Pod
kubectl get pods -n monitoring

# 应该看到：
# - loki-* Pods: Running
# - promtail-* Pods: Running
# - prometheus-* Pods: Running
# - grafana-* Pods: Running
# - alertmanager-* Pods: Running
```

#### 6.2 检查 PVC 状态

```bash
# 检查 PVC
kubectl get pvc -n monitoring

# 所有 PVC 应该是 Bound 状态
# 如果看到 Pending，检查：
# 1. StorageClass gp3 是否存在
# 2. EBS CSI Driver 是否运行
# 3. 节点是否有足够资源
```

#### 6.3 检查 ArgoCD Application 状态

```bash
# 检查所有 Application
kubectl get application -n argocd

# 应该都是 Synced 和 Healthy
```

#### 6.4 测试 Loki 功能

```bash
# 获取 Loki Gateway 地址
LOKI_GATEWAY=$(kubectl get svc -n monitoring loki-gateway -o jsonpath='{.spec.clusterIP}')

# 测试写入日志
kubectl run -it --rm test-loki --image=curlimages/curl:7.85.0 --restart=Never -- \
  curl -X POST http://${LOKI_GATEWAY}:8080/loki/api/v1/push \
  -H "Content-Type: application/json" \
  -d '{"streams":[{"stream":{"job":"test"},"values":[["'$(date +%s)000000000'","test message"]]}]}'

# 测试查询日志
kubectl run -it --rm test-loki-query --image=curlimages/curl:7.85.0 --restart=Never -- \
  curl "http://${LOKI_GATEWAY}:8080/loki/api/v1/query?query={job=\"test\"}"
```

#### 6.5 测试 Prometheus 功能

```bash
# Port-forward Prometheus
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090

# 在浏览器中访问 http://localhost:9090
# 或测试查询
curl http://localhost:9090/api/v1/query?query=up
```

#### 6.6 访问 Grafana

```bash
# 获取 Grafana 密码
kubectl get secret -n monitoring prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d && echo

# Port-forward Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

# 在浏览器中访问 http://localhost:3000
# 用户名: admin
# 密码: 从上面命令获取
```

---

## 🔧 关键配置说明

### 1. Loki 配置要点

#### 1.1 Schema 配置（必须）

Loki 3.0.0 要求使用 `schema: v13` 和 `store: tsdb`：

```yaml
loki:
  schemaConfig:
    configs:
      - from: "2020-10-24"
        store: tsdb # 必须
        object_store: s3
        schema: v13 # 必须
        index:
          prefix: index_
          period: 24h
  limits_config:
    allow_structured_metadata: false # 如果使用 v13，建议设置为 false
```

#### 1.2 StorageClass 配置（必须）

在 `simpleScalable` 模式下，必须为每个组件配置 `volumeClaimTemplate`：

```yaml
simpleScalable:
  backend:
    persistence:
      enabled: true
      storageClassName: gp3
      size: 10Gi
      volumeClaimTemplate: # 必须
        spec:
          storageClassName: gp3
  write:
    persistence:
      enabled: true
      storageClassName: gp3
      size: 10Gi
      volumeClaimTemplate: # 必须
        spec:
          storageClassName: gp3
```

#### 1.3 chunksCache 资源配置（重要）

如果节点资源有限，需要减少 chunksCache 的资源请求：

```yaml
chunksCache:
  enabled: true
  allocatedMemory: 1024 # MB，从默认 8192 减少
  resources:
    requests:
      cpu: 500m
      memory: 1Gi # 从默认 9830Mi 减少
    limits:
      memory: 2Gi
```

**注意**：`allocatedMemory` 应该小于或等于 `limits.memory`。

#### 1.4 S3 Bucket 名称同步

**重要问题**：Terraform 使用 `random_id` 生成 bucket 名称，每次可能不同。

**解决方案**：

1. 在 `loki-values-s3.yaml` 中使用占位符 `${LOKI_S3_BUCKET_NAME}`
2. 或使用脚本自动更新（`terraform/update-loki-values.sh`）
3. 或手动更新并提交到 Git

**验证**：

```bash
# 检查 ConfigMap 中的 bucket 名称
kubectl get configmap loki -n monitoring -o yaml | grep bucketnames

# 应该与 CDK 输出一致
aws cloudformation describe-stacks \
  --stack-name MonitoringStackStack \
  --query 'Stacks[0].Outputs[?OutputKey==`LokiBucketName`].OutputValue' \
  --output text
```

### 2. Prometheus 配置要点

#### 2.1 Grafana 数据源配置（必须使用 additionalDataSources）

**错误方式**（会导致冲突）：

```yaml
grafana:
  datasources: # ❌ 不要使用
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus
          isDefault: true
        - name: Loki
          isDefault: false
```

**正确方式**：

```yaml
grafana:
  additionalDataSources: # ✅ 使用这个
    - name: Loki
      type: loki
      access: proxy
      url: http://loki.monitoring.svc:3100
      isDefault: false # Prometheus 已由 kube-prometheus-stack 设置为默认
      editable: true
```

**原因**：`kube-prometheus-stack` 会自动创建 Prometheus 数据源，使用 `datasources` 会冲突。

#### 2.2 StorageClass 配置

```yaml
prometheus:
  prometheusSpec:
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3 # 必须
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 100Gi

grafana:
  persistence:
    storageClassName: gp3 # 必须
    size: 10Gi
```

### 3. ArgoCD Application 配置要点

#### 3.1 使用 sources（复数）支持多个仓库

```yaml
spec:
  sources: # ✅ 使用 sources（复数）
    - repoURL: https://grafana.github.io/helm-charts # Helm Chart 仓库
      chart: loki
      targetRevision: 6.0.0
      helm:
        valueFiles:
          - $values/monitoring/values/loki-values-s3.yaml
    - repoURL: https://github.com/<your-org>/<your-repo>.git # Git 仓库
      targetRevision: main
      ref: values # 标识这是 values 文件的来源
```

**关键点**：

- 第一个 source：Helm Chart 仓库
- 第二个 source：Git 仓库（提供 values 文件）
- `ref: values`：告诉 ArgoCD 这个 source 用于 values 文件

#### 3.2 Sync Policy 配置

```yaml
syncPolicy:
  automated:
    prune: true # 自动删除不在 Git 中的资源
    selfHeal: true # 自动修复配置漂移
  syncOptions:
    - CreateNamespace=true # 自动创建 namespace
    - PrunePropagationPolicy=foreground
    - PruneLast=true
    - ServerSideApply=true # 使用 Server-Side Apply
  retry:
    limit: 5
    backoff:
      duration: 5s
      factor: 2
      maxDuration: 3m
```

---

## ⚠️ 常见问题和解决方案

### 问题 1: PVC 无法绑定（Pending）

**错误信息**：

```
Events:
  Warning  FailedBinding  no persistent volumes available for this claim and no storage class is set
```

**原因**：

1. EBS CSI Driver 未安装或未运行
2. StorageClass `gp3` 不存在或配置错误
3. StorageClass 的 `provisioner` 不是 `ebs.csi.aws.com`

**解决方案**：

```bash
# 1. 检查 EBS CSI Driver
kubectl get pods -n kube-system | grep ebs-csi

# 2. 检查 StorageClass
kubectl get storageclass gp3 -o yaml

# 3. 如果 StorageClass 不存在，创建它（见 Step 0.2）

# 4. 如果 PVC 已创建但未绑定，删除并让 ArgoCD 重新创建
kubectl delete pvc -n monitoring <pvc-name>
# ArgoCD 会自动重新创建
```

### 问题 2: Loki Pod CrashLoopBackOff - Schema 错误

**错误信息**：

```
CONFIG ERROR: schema v13 is required
CONFIG ERROR: tsdb index type is required
```

**原因**：Loki values 文件中的 schema 配置不正确。

**解决方案**：

1. 更新 `monitoring/values/loki-values-s3.yaml`：

```yaml
loki:
  schemaConfig:
    configs:
      - from: "2020-10-24"
        store: tsdb # 必须
        object_store: s3
        schema: v13 # 必须
```

2. 提交到 Git：

```bash
git add monitoring/values/loki-values-s3.yaml
git commit -m "fix: Update Loki schema to v13 and tsdb"
git push origin main
```

3. 触发 ArgoCD 同步：

```bash
kubectl annotate application loki -n argocd argocd.argoproj.io/refresh=hard --overwrite
kubectl patch application loki -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main","prune":true}}}'
```

4. 重启 Loki Pods：

```bash
kubectl delete pod -n monitoring -l app.kubernetes.io/name=loki
```

### 问题 3: Grafana Pod CrashLoopBackOff - 数据源冲突

**错误信息**：

```
Datasource provisioning error: datasource.yaml config is invalid.
Only one datasource per organization can be marked as default
```

**原因**：使用了 `datasources` 而不是 `additionalDataSources`。

**解决方案**：

1. 更新 `monitoring/values/prometheus-values.yaml`：

```yaml
grafana:
  additionalDataSources: # ✅ 使用这个
    - name: Loki
      type: loki
      access: proxy
      url: http://loki.monitoring.svc:3100
      isDefault: false
```

2. 删除冲突的 ConfigMap：

```bash
kubectl delete configmap prometheus-grafana -n monitoring
kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana
```

3. 提交更改并触发同步：

```bash
git add monitoring/values/prometheus-values.yaml
git commit -m "fix: Use additionalDataSources for Loki"
git push origin main

kubectl annotate application prometheus -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

### 问题 4: Loki S3 访问错误 - MethodNotAllowed

**错误信息**：

```
WebIdentityErr: failed to retrieve credentials
MethodNotAllowed
```

**原因**：可能是 STS endpoint 问题，但通常不影响基本功能。

**验证**：

```bash
# 测试 Loki 功能
kubectl exec -n monitoring loki-gateway-xxx -- wget -qO- http://localhost:8080/loki/api/v1/labels

# 测试写入
kubectl exec -n monitoring loki-gateway-xxx -- wget -qO- --post-data='{"streams":[...]}' http://localhost:8080/loki/api/v1/push
```

**解决方案**：

- 如果功能正常，可以暂时忽略这些错误日志
- 如果功能异常，检查 IAM Role 信任策略和权限

### 问题 5: loki-chunks-cache-0 Pod Pending

**错误信息**：

```
Events:
  Warning  FailedScheduling  0/4 nodes are available: 4 Insufficient memory
```

**原因**：chunksCache 默认需要 9830Mi 内存，节点资源不足。

**解决方案**：

1. 减少资源请求（推荐）：

```yaml
chunksCache:
  enabled: true
  allocatedMemory: 1024 # MB
  resources:
    requests:
      memory: 1Gi # 从 9830Mi 减少
    limits:
      memory: 2Gi
```

2. 或禁用 chunksCache（如果不需要）：

```yaml
chunksCache:
  enabled: false
```

3. 提交更改并同步：

```bash
git add monitoring/values/loki-values-s3.yaml
git commit -m "fix: Reduce chunksCache resource requests"
git push origin main

kubectl annotate application loki -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

### 问题 6: S3 Bucket 名称不匹配

**错误信息**：

```
NoSuchBucket
```

**原因**：`loki-values-s3.yaml` 中的 bucket 名称与 Terraform 创建的不一致。

**解决方案**：

1. 获取正确的 bucket 名称：

```bash
# 如果使用 CDK
aws cloudformation describe-stacks \
  --stack-name MonitoringStackStack \
  --query 'Stacks[0].Outputs[?OutputKey==`LokiBucketName`].OutputValue' \
  --output text
```

2. 更新 values 文件：

```yaml
bucketNames:
  chunks: <correct-bucket-name>
  ruler: <correct-bucket-name>
```

3. 提交并同步：

```bash
git add monitoring/values/loki-values-s3.yaml
git commit -m "fix: Update Loki S3 bucket name"
git push origin main

kubectl annotate application loki -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

### 问题 7: ArgoCD Application 状态 Unknown

**错误信息**：

```
Status: Unknown
Message: failed to generate manifest
```

**可能原因**：

1. Git 仓库未配置或无法访问
2. values 文件路径错误
3. Helm Chart 版本不存在

**解决方案**：

```bash
# 1. 检查 Git 仓库配置
# 在 ArgoCD UI: Settings → Repositories

# 2. 检查 Application 配置
kubectl get application loki -n argocd -o yaml

# 3. 检查 ArgoCD 日志
kubectl logs -n argocd deployment/argocd-repo-server --tail=50

# 4. 手动触发同步
kubectl annotate application loki -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

---

## 📋 部署后验证清单

部署完成后，验证以下内容：

### Kubernetes 资源

- [ ] 所有 Pod 处于 `Running` 状态

  ```bash
  kubectl get pods -n monitoring
  ```

- [ ] 所有 PVC 处于 `Bound` 状态

  ```bash
  kubectl get pvc -n monitoring
  ```

- [ ] ArgoCD Applications 状态为 `Synced` 和 `Healthy`
  ```bash
  kubectl get application -n argocd
  ```

### AWS 资源

- [ ] S3 Bucket 存在且可访问

  ```bash
  # 如果使用 CDK
  BUCKET_NAME=$(aws cloudformation describe-stacks \
    --stack-name MonitoringStackStack \
    --query 'Stacks[0].Outputs[?OutputKey==`LokiBucketName`].OutputValue' \
    --output text)
  aws s3 ls s3://$BUCKET_NAME
  ```

- [ ] IAM Role 存在且配置正确

  ```bash
  aws iam get-role --role-name <cluster-name>-loki-s3-role
  ```

- [ ] ServiceAccount 有正确的 IRSA 注解
  ```bash
  kubectl get serviceaccount loki-s3-service-account -n monitoring -o yaml
  ```

### 功能验证

- [ ] Loki 可以写入和查询日志

  ```bash
  # 见 Step 6.4
  ```

- [ ] Prometheus 可以收集 Metrics

  ```bash
  kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090
  # 访问 http://localhost:9090
  ```

- [ ] Grafana 可以访问，数据源配置正确

  ```bash
  kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
  # 访问 http://localhost:3000
  # 检查 Data Sources → 应该有 Prometheus 和 Loki
  ```

- [ ] Promtail 正在收集日志
  ```bash
  kubectl logs -n monitoring -l app.kubernetes.io/name=promtail --tail=20
  ```

---

## 🔄 更新和维护

### 更新配置

1. 修改 values 文件
2. 提交到 Git
3. ArgoCD 会自动同步（如果启用了 `automated`）

### 手动触发同步

```bash
# 刷新并同步
kubectl annotate application <app-name> -n argocd argocd.argoproj.io/refresh=hard --overwrite

# 或通过 ArgoCD UI
# 点击 Application → Sync
```

### 回滚

```bash
# 查看历史版本
kubectl get application <app-name> -n argocd -o yaml | grep revision

# 回滚到特定版本
kubectl patch application <app-name> -n argocd --type merge -p '{"spec":{"source":{"targetRevision":"<commit-hash>"}}}'
```

---

## 📚 参考文档

- [DEBUG.md](./DEBUG.md) - 详细的问题排查指南
- [GRAFANA-USAGE-GUIDE.md](./GRAFANA-USAGE-GUIDE.md) - Grafana 使用指南
- [CLEANUP-GUIDE.md](./CLEANUP-GUIDE.md) - 资源清理指南
- [Loki Helm Chart](https://github.com/grafana/helm-charts/tree/main/charts/loki)
- [Prometheus Helm Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)

---

## 🎯 总结

在已有集群上部署监控栈的关键点：

1. **检查现有资源**：EBS CSI Driver、StorageClass、OIDC Provider
2. **只创建必要的 AWS 资源**：S3 Bucket、IAM Role
3. **正确配置 IRSA**：ServiceAccount 注解必须正确
4. **使用 additionalDataSources**：避免 Grafana 数据源冲突
5. **正确配置 Loki Schema**：v13 + tsdb
6. **配置 volumeClaimTemplate**：确保 PVC 使用正确的 StorageClass
7. **使用 sources（复数）**：支持多个仓库源
8. **及时提交 Git**：ArgoCD 从 Git 读取配置

遵循本指南，可以安全地在已有集群上部署监控栈，避免资源冲突和配置错误。
