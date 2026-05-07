#!/bin/bash
# scripts/bootstrap_state.sh
# Run ONCE before first terraform init — creates S3 state bucket + DynamoDB lock table
# Usage: bash scripts/bootstrap_state.sh

set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-south-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="iac-terraform-state-prod"
DYNAMO_TABLE="terraform-state-lock"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Terraform Remote State Bootstrap                  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Account : $ACCOUNT_ID"
echo "  Region  : $REGION"
echo "  Bucket  : $BUCKET"
echo "  DynamoDB: $DYNAMO_TABLE"
echo ""

# ── Create S3 bucket ──────────────────────────────────────────────
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    echo "✅ S3 bucket already exists: $BUCKET"
else
    echo "📦 Creating S3 bucket: $BUCKET"
    if [ "$REGION" = "us-east-1" ]; then
        aws s3api create-bucket \
            --bucket "$BUCKET" \
            --region "$REGION"
    else
        aws s3api create-bucket \
            --bucket "$BUCKET" \
            --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION"
    fi
    echo "✅ Bucket created"
fi

# Enable versioning (required for Terraform state)
aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled
echo "✅ Versioning enabled"

# Enable server-side encryption
aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration '{
        "Rules": [{
            "ApplyServerSideEncryptionByDefault": {
                "SSEAlgorithm": "AES256"
            }
        }]
    }'
echo "✅ Encryption (AES-256) enabled"

# Block all public access
aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "✅ Public access blocked"

# ── Create DynamoDB table for state locking ───────────────────────
if aws dynamodb describe-table --table-name "$DYNAMO_TABLE" --region "$REGION" 2>/dev/null; then
    echo "✅ DynamoDB table already exists: $DYNAMO_TABLE"
else
    echo "🔒 Creating DynamoDB lock table: $DYNAMO_TABLE"
    aws dynamodb create-table \
        --table-name "$DYNAMO_TABLE" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "$REGION"
    
    echo "⏳ Waiting for table to be active..."
    aws dynamodb wait table-exists --table-name "$DYNAMO_TABLE" --region "$REGION"
    echo "✅ DynamoDB table ready"
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Bootstrap complete! Next steps:                   ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║   cd terraform/environments/prod                    ║"
echo "║   terraform init                                    ║"
echo "║   terraform plan                                    ║"
echo "║   terraform apply                                   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
