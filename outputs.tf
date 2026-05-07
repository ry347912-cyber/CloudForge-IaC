# terraform/environments/prod/outputs.tf

output "alb_dns_name" {
  description = "ALB endpoint — point your domain CNAME here"
  value       = module.alb.alb_dns_name
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = module.rds.db_endpoint
  sensitive   = true
}

output "dashboard_url" {
  description = "FinOps cost dashboard (S3 static site)"
  value       = "http://${aws_s3_bucket.dashboard.bucket}.s3-website.${var.aws_region}.amazonaws.com"
}

output "asg_name" {
  description = "Auto Scaling Group name"
  value       = module.ec2.asg_name
}

output "cost_lambda_name" {
  description = "Cost reporter Lambda function name"
  value       = aws_lambda_function.cost_reporter.function_name
}
