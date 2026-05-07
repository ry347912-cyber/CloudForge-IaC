# terraform/environments/prod/variables.tf

variable "aws_region"   { type = string  default = "ap-south-1" }
variable "project"      { type = string  default = "iac-demo" }
variable "environment"  { type = string  default = "prod" }
variable "owner_email"  { type = string  default = "you@example.com" }

# Networking
variable "vpc_cidr"             { type = string  default = "10.0.0.0/16" }
variable "public_subnet_cidrs"  { type = list(string)  default = ["10.0.1.0/24", "10.0.2.0/24"] }
variable "private_subnet_cidrs" { type = list(string)  default = ["10.0.11.0/24", "10.0.12.0/24"] }
variable "db_subnet_cidrs"      { type = list(string)  default = ["10.0.21.0/24", "10.0.22.0/24"] }
variable "availability_zones"   { type = list(string)  default = ["ap-south-1a", "ap-south-1b"] }

# EC2
variable "instance_type"   { type = string  default = "t3.micro" }
variable "public_key_path" { type = string  default = "~/.ssh/id_rsa.pub" }
variable "asg_min"         { type = number  default = 1 }
variable "asg_max"         { type = number  default = 3 }
variable "asg_desired"     { type = number  default = 2 }

# RDS
variable "db_instance_class" { type = string  default = "db.t3.micro" }
variable "db_name"           { type = string  default = "appdb" }
variable "db_username"       { type = string  default = "dbadmin" }
variable "db_password"       { type = string  sensitive = true }
variable "multi_az"          { type = bool    default = false }  # Set true for prod!

# ALB / SSL
variable "acm_certificate_arn" { type = string  default = "" }

# FinOps Dashboard
variable "slack_webhook_url" { type = string  sensitive = true  default = "" }
