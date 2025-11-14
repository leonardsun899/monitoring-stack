#!/bin/bash
# 自动更新 Loki values 文件，使用 Terraform 输出值

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_ROOT}"

# 检查 Terraform 是否已初始化
if [ ! -d "terraform/.terraform" ]; then
  echo "❌ 错误：Terraform 尚未初始化。请先运行 'cd terraform && terraform init'"
  exit 1
fi

# 获取 Terraform 输出值
echo "📡 获取 Terraform 输出值..."
BUCKET_NAME=$(terraform -chdir=terraform output -raw loki_s3_bucket_name 2>/dev/null || echo "")
AWS_REGION=$(terraform -chdir=terraform output -raw aws_region 2>/dev/null || \
  grep -E '^\s*aws_region\s*=' terraform/terraform.tfvars 2>/dev/null | sed 's/.*=\s*"\(.*\)".*/\1/' || \
  echo "us-west-2")

if [ -z "$BUCKET_NAME" ]; then
  echo "❌ 错误：无法获取 S3 存储桶名称。请确保 Terraform 已成功部署。"
  exit 1
fi

echo "✅ 获取到以下值："
echo "   S3 Bucket: ${BUCKET_NAME}"
echo "   AWS Region: ${AWS_REGION}"

# 备份原文件
VALUES_FILE="monitoring/values/loki-values-s3.yaml"
if [ -f "${VALUES_FILE}" ]; then
  cp "${VALUES_FILE}" "${VALUES_FILE}.bak"
  echo "📋 已备份原文件到 ${VALUES_FILE}.bak"
fi

# 更新 values 文件
echo "🔄 更新 ${VALUES_FILE}..."
sed -i.tmp \
  -e "s|\${LOKI_S3_BUCKET_NAME}|${BUCKET_NAME}|g" \
  -e "s|\${AWS_REGION}|${AWS_REGION}|g" \
  "${VALUES_FILE}"

# 删除临时文件
rm -f "${VALUES_FILE}.tmp"

echo "✅ 已成功更新 ${VALUES_FILE}"
echo ""
echo "📝 请检查文件内容，确保配置正确："
echo "   - S3 Bucket: ${BUCKET_NAME}"
echo "   - AWS Region: ${AWS_REGION}"
echo "   - ServiceAccount: loki-s3-service-account"

