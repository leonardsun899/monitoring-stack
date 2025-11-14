#!/bin/bash

# Loki Sync Error 修复脚本
# 此脚本会清除 ArgoCD 缓存并强制刷新 Loki 应用

echo "🔧 开始修复 Loki 同步错误..."

# 1. 清除 ArgoCD 缓存并强制刷新
echo "📋 步骤 1: 清除 ArgoCD 缓存并强制刷新..."
kubectl patch application loki -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# 等待几秒钟
sleep 5

# 2. 检查 Application 状态
echo "📋 步骤 2: 检查 Application 状态..."
kubectl get application loki -n argocd

# 3. 如果还是失败，尝试手动同步
echo "📋 步骤 3: 如果状态不是 Synced，可以尝试手动同步..."
echo "   在 ArgoCD UI 中点击 'Sync' 按钮，或运行："
echo "   kubectl patch application loki -n argocd --type merge -p '{\"operation\":{\"initiatedBy\":{\"username\":\"admin\"},\"sync\":{\"revision\":\"main\"}}}'"

# 4. 查看详细错误（如果还有）
echo ""
echo "📋 如果还有错误，查看详细信息："
echo "   kubectl describe application loki -n argocd"
echo "   kubectl get application loki -n argocd -o yaml"

echo ""
echo "✅ 修复脚本执行完成！"

