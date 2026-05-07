# terraform/environments/prod/terraform.tfvars
# Copy this file and fill in your actual values
# NEVER commit real secrets — use environment variables for sensitive values:
#   export TF_VAR_db_password="YourStrongPassword123!"
#   export TF_VAR_slack_webhook_url="https://hooks.slack.com/services/xxx/yyy/zzz"

aws_region  = "ap-south-1"
project     = "iac-demo"
environment = "prod"
owner_email = "you@example.com"

# Networking
vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24"]
db_subnet_cidrs      = ["10.0.21.0/24", "10.0.22.0/24"]
availability_zones   = ["ap-south-1a", "ap-south-1b"]

# EC2 / ASG
instance_type   = "t3.micro"
public_key_path = "~/.ssh/id_rsa.pub"
asg_min         = 1
asg_max         = 3
asg_desired     = 2

# RDS
db_instance_class = "db.t3.micro"
db_name           = "appdb"
db_username       = "dbadmin"
multi_az          = false   # Set true for real prod (costs more)

# Sensitive — set via env vars, not here:
# db_password       = "set via TF_VAR_db_password"
# slack_webhook_url = "set via TF_VAR_slack_webhook_url"

# ALB / SSL — leave empty to skip HTTPS (HTTP only for demo)
acm_certificate_arn = ""
