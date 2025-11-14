#!/bin/bash

# DigitalOcean Spaces 配置 - 命令行步骤
# 这个脚本提供所有需要的命令，你可以一步步复制执行

echo "=========================================="
echo "DigitalOcean Spaces 配置 - 命令行步骤"
echo "=========================================="
echo ""

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}步骤 1: 创建 DigitalOcean Spaces${NC}"
echo "----------------------------------------"
echo "方法 1: 使用控制面板（推荐）"
echo "  访问: https://cloud.digitalocean.com/spaces"
echo "  点击 'Create a Space'"
echo "  名称: loki-storage-sgp1"
echo "  区域: Singapore (sgp1)"
echo ""
echo "方法 2: 使用 doctl（如果支持）"
echo "  doctl spaces create loki-storage-sgp1 --region sgp1"
echo ""
read -p "按回车继续下一步..."

echo ""
echo -e "${YELLOW}步骤 2: 创建访问密钥${NC}"
echo "----------------------------------------"
echo "方法 1: 使用控制面板（推荐）"
echo "  访问: https://cloud.digitalocean.com/account/api/spaces"
echo "  点击 'Generate New Key'"
echo "  名称: loki-spaces-key"
echo ""
echo "方法 2: 使用 doctl"
echo "  doctl spaces keys create loki-spaces-key"
echo ""
echo "请保存 Access Key 和 Secret Key"
echo ""
read -p "按回车继续下一步..."

echo ""
echo -e "${YELLOW}步骤 3: 设置变量${NC}"
echo "----------------------------------------"
echo "请运行以下命令，替换为你的实际值："
echo ""
cat << 'EOF'
export SPACE_NAME="loki-storage-sgp1"  # 替换为你的 Spaces 名称
export REGION="sgp1"                    # 替换为你的区域
export ENDPOINT="sgp1.digitaloceanspaces.com"  # 根据区域调整
export ACCESS_KEY="你的 Access Key"     # 替换为你的 Access Key
export SECRET_KEY="你的 Secret Key"     # 替换为你的 Secret Key
EOF
echo ""
read -p "设置完变量后按回车继续..."

echo ""
echo -e "${YELLOW}步骤 4: 创建 Kubernetes Secret${NC}"
echo "----------------------------------------"
cat << 'EOF'
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl delete secret loki-spaces-credentials -n monitoring --ignore-not-found=true
kubectl create secret generic loki-spaces-credentials \
  --from-literal=AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
  --namespace monitoring
EOF
echo ""
read -p "执行完命令后按回车继续..."

echo ""
echo -e "${YELLOW}步骤 5: 更新 Loki 配置文件${NC}"
echo "----------------------------------------"
cat << 'EOF'
sed -i.bak \
  -e "s/chunks: loki-storage/chunks: $SPACE_NAME/g" \
  -e "s/ruler: loki-storage/ruler: $SPACE_NAME/g" \
  -e "s|endpoint: sgp1.digitaloceanspaces.com|endpoint: $ENDPOINT|g" \
  -e "s/region: sgp1/region: $REGION/g" \
  monitoring/values/loki-values-default.yaml
rm -f monitoring/values/loki-values-default.yaml.bak
EOF
echo ""
read -p "执行完命令后按回车继续..."

echo ""
echo -e "${YELLOW}步骤 6: 更新 ArgoCD Application${NC}"
echo "----------------------------------------"
cat << 'EOF'
sed -i.bak 's|loki-values.yaml|loki-values-default.yaml|g' monitoring/argocd/loki.yaml
rm -f monitoring/argocd/loki.yaml.bak
EOF
echo ""
read -p "执行完命令后按回车继续..."

echo ""
echo -e "${YELLOW}步骤 7: 提交到 Git${NC}"
echo "----------------------------------------"
cat << 'EOF'
git add monitoring/values/loki-values-default.yaml monitoring/argocd/loki.yaml
git commit -m "feat: Configure Loki to use DigitalOcean Spaces ($SPACE_NAME)"
git push origin main
EOF
echo ""
read -p "执行完命令后按回车继续..."

echo ""
echo -e "${GREEN}✅ 配置完成！${NC}"
echo ""
echo "验证命令："
echo "  kubectl get application loki -n argocd"
echo "  kubectl get pods -n monitoring -l app.kubernetes.io/name=loki"
echo "  kubectl logs -n monitoring -l app.kubernetes.io/name=loki --tail=50"

