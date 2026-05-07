#!/bin/bash
# scripts/destroy.sh
# Safely destroys all Terraform-managed resources
# Requires typing the project name to confirm

set -euo pipefail

PROJECT="iac-demo"
ENVIRONMENT="${1:-prod}"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   ⚠️  INFRASTRUCTURE DESTROY WARNING                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  This will PERMANENTLY DELETE all AWS resources for:"
echo "  Project     : $PROJECT"
echo "  Environment : $ENVIRONMENT"
echo ""
echo "  Resources that will be destroyed:"
echo "  - VPC, subnets, NAT Gateway"
echo "  - EC2 instances / Auto Scaling Group"
echo "  - RDS PostgreSQL database + ALL DATA"
echo "  - Application Load Balancer"
echo "  - S3 buckets (logs + dashboard)"
echo "  - Lambda function + CloudWatch events"
echo ""
read -p "  Type the project name '$PROJECT' to confirm: " confirm

if [ "$confirm" != "$PROJECT" ]; then
    echo ""
    echo "❌ Confirmation failed. Destroy cancelled."
    exit 1
fi

echo ""
echo "🔥 Starting destroy..."
echo ""

cd "$(dirname "$0")/../terraform/environments/$ENVIRONMENT"

terraform init -input=false

terraform destroy \
    -var="db_password=${TF_VAR_db_password:-placeholder}" \
    -auto-approve

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   ✅ Destroy complete. All resources removed.       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
