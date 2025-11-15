#!/bin/bash
# Automatically update Loki values file using Terraform output values

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_ROOT}"

# Check if Terraform is initialized
if [ ! -d "terraform/.terraform" ]; then
  echo "❌ Error: Terraform not initialized. Please run 'cd terraform && terraform init' first"
  exit 1
fi

# Get Terraform output values
echo "📡 Getting Terraform output values..."
BUCKET_NAME=$(terraform -chdir=terraform output -raw loki_s3_bucket_name 2>/dev/null || echo "")
AWS_REGION=$(terraform -chdir=terraform output -raw aws_region 2>/dev/null || \
  grep -E '^\s*aws_region\s*=' terraform/terraform.tfvars 2>/dev/null | sed 's/.*=\s*"\(.*\)".*/\1/' || \
  echo "us-west-2")

if [ -z "$BUCKET_NAME" ]; then
  echo "❌ Error: Unable to get S3 bucket name. Please ensure Terraform has been successfully deployed."
  exit 1
fi

echo "✅ Retrieved the following values:"
echo "   S3 Bucket: ${BUCKET_NAME}"
echo "   AWS Region: ${AWS_REGION}"

# Backup original file
VALUES_FILE="monitoring/values/loki-values-s3.yaml"
if [ -f "${VALUES_FILE}" ]; then
  cp "${VALUES_FILE}" "${VALUES_FILE}.bak"
  echo "📋 Backed up original file to ${VALUES_FILE}.bak"
fi

# Update values file
echo "🔄 Updating ${VALUES_FILE}..."
sed -i.tmp \
  -e "s|\${LOKI_S3_BUCKET_NAME}|${BUCKET_NAME}|g" \
  -e "s|\${AWS_REGION}|${AWS_REGION}|g" \
  "${VALUES_FILE}"

# Remove temporary file
rm -f "${VALUES_FILE}.tmp"

echo "✅ Successfully updated ${VALUES_FILE}"
echo ""
echo "📝 Please check the file content to ensure configuration is correct:"
echo "   - S3 Bucket: ${BUCKET_NAME}"
echo "   - AWS Region: ${AWS_REGION}"
echo "   - ServiceAccount: loki-s3-service-account"

