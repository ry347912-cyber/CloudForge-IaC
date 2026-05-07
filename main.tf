# terraform/environments/prod/main.tf
# Wires all modules together — this is the entry point

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state in S3 — prevents concurrent apply conflicts
  backend "s3" {
    bucket         = "iac-terraform-state-prod"   # Created by bootstrap_state.sh
    key            = "prod/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "terraform-state-lock"       # DynamoDB for state locking
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = local.common_tags }
}

locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = var.owner_email
  }
}

# ─── S3 Bucket for ALB Logs + Dashboard ──────────────────────────
resource "aws_s3_bucket" "logs" {
  bucket        = "${var.project}-${var.environment}-alb-logs"
  force_destroy = true
  tags          = local.common_tags
}

resource "aws_s3_bucket" "dashboard" {
  bucket        = "${var.project}-cost-dashboard-${var.environment}"
  force_destroy = true
  tags          = local.common_tags
}

resource "aws_s3_bucket_website_configuration" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id
  index_document { suffix = "index.html" }
}

resource "aws_s3_bucket_public_access_block" "dashboard" {
  bucket                  = aws_s3_bucket.dashboard.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "dashboard_public" {
  bucket     = aws_s3_bucket.dashboard.id
  depends_on = [aws_s3_bucket_public_access_block.dashboard]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.dashboard.arn}/*"
    }]
  })
}

# ─── VPC Module ───────────────────────────────────────────────────
module "vpc" {
  source = "../../modules/vpc"

  project     = var.project
  environment = var.environment
  vpc_cidr    = var.vpc_cidr

  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  db_subnet_cidrs      = var.db_subnet_cidrs
  availability_zones   = var.availability_zones
  tags                 = local.common_tags
}

# ─── Security Groups Module ───────────────────────────────────────
module "security" {
  source = "../../modules/security"

  project     = var.project
  environment = var.environment
  vpc_id      = module.vpc.vpc_id
  vpc_cidr    = module.vpc.vpc_cidr
  tags        = local.common_tags
}

# ─── ALB Module ───────────────────────────────────────────────────
module "alb" {
  source = "../../modules/alb"

  project             = var.project
  environment         = var.environment
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  alb_sg_id           = module.security.alb_sg_id
  logs_bucket         = aws_s3_bucket.logs.bucket
  acm_certificate_arn = var.acm_certificate_arn
  tags                = local.common_tags
}

# ─── EC2 / ASG Module ────────────────────────────────────────────
module "ec2" {
  source = "../../modules/ec2"

  project            = var.project
  environment        = var.environment
  instance_type      = var.instance_type
  public_key_path    = var.public_key_path
  private_subnet_ids = module.vpc.private_subnet_ids
  ec2_sg_id          = module.security.ec2_sg_id
  target_group_arn   = module.alb.target_group_arn
  asg_min            = var.asg_min
  asg_max            = var.asg_max
  asg_desired        = var.asg_desired
  tags               = local.common_tags
}

# ─── RDS Module ───────────────────────────────────────────────────
module "rds" {
  source = "../../modules/rds"

  project           = var.project
  environment       = var.environment
  db_subnet_ids     = module.vpc.db_subnet_ids
  rds_sg_id         = module.security.rds_sg_id
  db_instance_class = var.db_instance_class
  db_name           = var.db_name
  db_username       = var.db_username
  db_password       = var.db_password
  multi_az          = var.multi_az
  tags              = local.common_tags
}

# ─── Lambda Cost Reporter ─────────────────────────────────────────
resource "aws_iam_role" "lambda_cost" {
  name = "${var.project}-lambda-cost-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_cost" {
  name = "cost-reporter-policy"
  role = aws_iam_role.lambda_cost.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ce:GetCostAndUsage", "ce:GetCostForecast"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.dashboard.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../../../lambda/cost_reporter"
  output_path = "${path.root}/lambda_cost_reporter.zip"
}

resource "aws_lambda_function" "cost_reporter" {
  function_name    = "${var.project}-${var.environment}-cost-reporter"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  role             = aws_iam_role.lambda_cost.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"
  timeout          = 60

  environment {
    variables = {
      DASHBOARD_BUCKET = aws_s3_bucket.dashboard.bucket
      SLACK_WEBHOOK    = var.slack_webhook_url
      PROJECT          = var.project
      ENVIRONMENT      = var.environment
      AWS_REGION_NAME  = var.aws_region
    }
  }

  tags = local.common_tags
}

# Trigger Lambda immediately after apply via null_resource
resource "null_resource" "trigger_cost_report" {
  depends_on = [
    module.ec2, module.rds, module.alb,
    aws_lambda_function.cost_reporter
  ]

  triggers = { always_run = timestamp() }

  provisioner "local-exec" {
    command = <<-EOF
      aws lambda invoke \
        --function-name ${aws_lambda_function.cost_reporter.function_name} \
        --region ${var.aws_region} \
        --payload '{}' \
        /tmp/lambda_response.json && \
      echo "✅ Cost report triggered. Check Slack!" && \
      cat /tmp/lambda_response.json
    EOF
  }
}

# Also schedule Lambda every day at 8am IST (2:30 UTC)
resource "aws_cloudwatch_event_rule" "daily_cost" {
  name                = "${var.project}-daily-cost-report"
  schedule_expression = "cron(30 2 * * ? *)"
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "cost_lambda" {
  rule      = aws_cloudwatch_event_rule.daily_cost.name
  target_id = "CostReporterLambda"
  arn       = aws_lambda_function.cost_reporter.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_reporter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_cost.arn
}
