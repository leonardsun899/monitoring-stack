#!/bin/bash

# Loki DigitalOcean Spaces 自动化配置脚本
# 使用 doctl 创建 Spaces 并配置 Loki

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 配置变量（可以根据需要修改）
SPACE_NAME="loki-storage-$(date +%s)"  # 使用时间戳确保唯一性
REGION="nyc3"  # 默认区域，可以根据需要修改
KEY_NAME="loki-spaces-key"
NAMESPACE="monitoring"
SECRET_NAME="loki-spaces-credentials"

echo -e "${GREEN}🚀 开始配置 Loki 使用 DigitalOcean Spaces${NC}"
echo ""

# 检查 doctl 是否安装
if ! command -v doctl &> /dev/null; then
    echo -e "${RED}❌ doctl 未安装。请先安装 DigitalOcean CLI${NC}"
    echo "安装方法: https://docs.digitalocean.com/reference/doctl/how-to/install/"
    exit 1
fi

# 检查 doctl 是否已认证
if ! doctl auth list &> /dev/null; then
    echo -e "${RED}❌ doctl 未认证。请先运行: doctl auth init${NC}"
    exit 1
fi

echo -e "${YELLOW}📋 步骤 1: 创建 DigitalOcean Spaces${NC}"

# 检查 Spaces 是否已存在
if doctl spaces list | grep -q "$SPACE_NAME"; then
    echo -e "${YELLOW}⚠️  Spaces '$SPACE_NAME' 已存在，跳过创建${NC}"
else
    echo "创建 Spaces: $SPACE_NAME (区域: $REGION)"
    
    # 注意: doctl 可能不支持直接创建 Spaces，需要通过 API
    # 这里提供手动步骤和 API 调用方法
    echo -e "${YELLOW}⚠️  doctl 可能不支持直接创建 Spaces${NC}"
    echo "请手动在 DigitalOcean 控制面板创建 Spaces，或使用以下 API 调用："
    echo ""
    echo "或者使用以下命令（需要 doctl 支持）："
    echo "  doctl compute cdn create $SPACE_NAME --region $REGION"
    echo ""
    read -p "是否已手动创建 Spaces？(y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}请先创建 Spaces，然后重新运行此脚本${NC}"
        echo "创建步骤："
        echo "1. 访问 https://cloud.digitalocean.com/spaces"
        echo "2. 点击 'Create a Space'"
        echo "3. 输入名称: $SPACE_NAME"
        echo "4. 选择区域: $REGION"
        echo "5. 创建"
        exit 1
    fi
fi

# 获取用户输入的 Spaces 名称和区域
read -p "请输入你的 Spaces 名称: " SPACE_NAME
read -p "请输入你的 Spaces 区域 (例如 nyc3, sfo3, sgp1): " REGION

# 验证 Spaces 是否存在
if ! doctl spaces list 2>/dev/null | grep -q "$SPACE_NAME"; then
    echo -e "${YELLOW}⚠️  无法验证 Spaces 是否存在，继续执行...${NC}"
fi

echo -e "${GREEN}✅ Spaces 配置: $SPACE_NAME (区域: $REGION)${NC}"
echo ""

echo -e "${YELLOW}📋 步骤 2: 创建访问密钥${NC}"
echo "访问密钥需要在 DigitalOcean 控制面板手动创建："
echo "1. 访问 https://cloud.digitalocean.com/account/api/spaces"
echo "2. 点击 'Generate New Key'"
echo "3. 输入名称: $KEY_NAME"
echo "4. 保存 Access Key 和 Secret Key"
echo ""

read -p "请输入 Access Key: " ACCESS_KEY
read -p "请输入 Secret Key: " SECRET_KEY

if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ]; then
    echo -e "${RED}❌ Access Key 和 Secret Key 不能为空${NC}"
    exit 1
fi

echo -e "${GREEN}✅ 访问密钥已获取${NC}"
echo ""

echo -e "${YELLOW}📋 步骤 3: 创建 Kubernetes Secret${NC}"

# 检查命名空间是否存在
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo "创建命名空间: $NAMESPACE"
    kubectl create namespace "$NAMESPACE"
fi

# 删除已存在的 Secret（如果存在）
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
    echo "删除已存在的 Secret: $SECRET_NAME"
    kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE"
fi

# 创建新的 Secret
echo "创建 Kubernetes Secret: $SECRET_NAME"
kubectl create secret generic "$SECRET_NAME" \
  --from-literal=AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
  --namespace "$NAMESPACE"

echo -e "${GREEN}✅ Kubernetes Secret 已创建${NC}"
echo ""

echo -e "${YELLOW}📋 步骤 4: 更新 Loki 配置文件${NC}"

# 确定区域端点
case $REGION in
    nyc1|nyc3)
        ENDPOINT="nyc3.digitaloceanspaces.com"
        ;;
    sfo2|sfo3)
        ENDPOINT="sfo3.digitaloceanspaces.com"
        ;;
    sgp1)
        ENDPOINT="sgp1.digitaloceanspaces.com"
        ;;
    ams3)
        ENDPOINT="ams3.digitaloceanspaces.com"
        ;;
    fra1)
        ENDPOINT="fra1.digitaloceanspaces.com"
        ;;
    *)
        ENDPOINT="${REGION}.digitaloceanspaces.com"
        ;;
esac

# 更新 loki-values-default.yaml (使用默认配置)
VALUES_FILE="monitoring/values/loki-values-default.yaml"

if [ ! -f "$VALUES_FILE" ]; then
    echo -e "${RED}❌ 文件不存在: $VALUES_FILE${NC}"
    exit 1
fi

# 备份原文件
cp "$VALUES_FILE" "${VALUES_FILE}.backup"

# 更新配置
sed -i.bak "s/chunks: loki-storage/chunks: $SPACE_NAME/g" "$VALUES_FILE"
sed -i.bak "s/ruler: loki-storage/ruler: $SPACE_NAME/g" "$VALUES_FILE"
sed -i.bak "s|endpoint: nyc3.digitaloceanspaces.com|endpoint: $ENDPOINT|g" "$VALUES_FILE"
sed -i.bak "s/region: nyc3/region: $REGION/g" "$VALUES_FILE"

# 清理备份文件
rm -f "${VALUES_FILE}.bak"

echo -e "${GREEN}✅ Loki 配置文件已更新${NC}"
echo ""

echo -e "${YELLOW}📋 步骤 5: 更新 ArgoCD Application${NC}"

# 更新 ArgoCD Application 使用 Spaces 配置
ARGO_APP_FILE="monitoring/argocd/loki.yaml"

if [ ! -f "$ARGO_APP_FILE" ]; then
    echo -e "${RED}❌ 文件不存在: $ARGO_APP_FILE${NC}"
    exit 1
fi

# 备份原文件
cp "$ARGO_APP_FILE" "${ARGO_APP_FILE}.backup"

# 更新 values 文件路径
sed -i.bak 's|loki-values.yaml|loki-values-default.yaml|g' "$ARGO_APP_FILE"

# 清理备份文件
rm -f "${ARGO_APP_FILE}.bak"

echo -e "${GREEN}✅ ArgoCD Application 已更新${NC}"
echo ""

echo -e "${YELLOW}📋 步骤 6: 提交更改到 Git${NC}"

# 检查 Git 状态
if ! git status &> /dev/null; then
    echo -e "${YELLOW}⚠️  当前目录不是 Git 仓库，跳过 Git 提交${NC}"
else
    echo "添加更改的文件..."
    git add "$VALUES_FILE" "$ARGO_APP_FILE"
    
    read -p "是否提交并推送到 Git？(y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git commit -m "feat: Configure Loki to use DigitalOcean Spaces ($SPACE_NAME)"
        git push origin main
        echo -e "${GREEN}✅ 更改已提交并推送${NC}"
    else
        echo -e "${YELLOW}⚠️  更改已暂存，但未提交${NC}"
        echo "可以稍后手动提交："
        echo "  git commit -m 'feat: Configure Loki to use DigitalOcean Spaces'"
        echo "  git push origin main"
    fi
fi

echo ""
echo -e "${GREEN}🎉 配置完成！${NC}"
echo ""
echo "📋 配置摘要："
echo "  - Spaces 名称: $SPACE_NAME"
echo "  - 区域: $REGION"
echo "  - 端点: $ENDPOINT"
echo "  - Kubernetes Secret: $SECRET_NAME (命名空间: $NAMESPACE)"
echo "  - Values 文件: $VALUES_FILE"
echo "  - ArgoCD Application: $ARGO_APP_FILE"
echo ""
echo "🔄 下一步："
echo "1. ArgoCD 会自动同步更改（如果启用了 auto-sync）"
echo "2. 或者手动在 ArgoCD UI 中同步 Loki 应用"
echo "3. 检查 Loki Pod 状态: kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=loki"
echo ""
echo "🔍 验证："
echo "  kubectl get application loki -n argocd"
echo "  kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=loki"
echo "  kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=loki --tail=50"

