# GitHub Secrets Setup Guide
# Add these secrets in: GitHub repo → Settings → Secrets → Actions

Required secrets:
  AWS_ACCESS_KEY_ID         = Your IAM user access key
  AWS_SECRET_ACCESS_KEY     = Your IAM user secret key
  TF_VAR_DB_PASSWORD        = Your RDS database password (min 8 chars)
  SLACK_WEBHOOK_URL         = https://hooks.slack.com/services/xxx/yyy/zzz

How to get a Slack Webhook:
  1. Go to https://api.slack.com/apps
  2. Create New App → From Scratch
  3. Incoming Webhooks → Activate
  4. Add New Webhook to Workspace → Select #devops-alerts channel
  5. Copy webhook URL → paste as SLACK_WEBHOOK_URL secret

IAM permissions needed (create a dedicated IAM user):
  AmazonEC2FullAccess
  AmazonRDSFullAccess
  AmazonVPCFullAccess
  ElasticLoadBalancingFullAccess
  AmazonS3FullAccess
  IAMFullAccess
  AWSLambda_FullAccess
  AmazonDynamoDBFullAccess
  CloudWatchEventsFullAccess
  ce:GetCostAndUsage (Cost Explorer)
