# Provider configuration
provider "aws" {
  region = "us-west-2"
  shared_config_files      = ["/Users/tf_user/.aws/conf"]
  shared_credentials_files = ["/Users/tf_user/.aws/creds"]
}

# Variables
variable "project_name" {
  description = "The name of the project"
  type        = string
  default     = "streamscribe"
}

variable "environment" {
  description = "The deployment environment"
  type        = string
  default     = "dev"
}

# Locals for bucket naming
locals {
  bucket_name   = "${var.project_name}-${var.environment}-storage"
  bucket_exists = can(data.aws_s3_bucket.existing_bucket[0].id)
}

# Data source to check if the S3 bucket already exists
data "aws_s3_bucket" "existing_bucket" {
  count  = try(data.aws_s3_bucket.existing_bucket[0].id, "") != "" ? 1 : 0
  bucket = local.bucket_name
}

# S3 bucket for video and processed data storage
resource "aws_s3_bucket" "video_storage" {
  # Only create if the bucket doesn't exist
  count  = local.bucket_exists ? 0 : 1
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "${var.project_name}-video-storage"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Use this local for references to the bucket
locals {
  bucket_id = local.bucket_exists ? data.aws_s3_bucket.existing_bucket[0].id : try(aws_s3_bucket.video_storage[0].id, local.bucket_name)
}

# Enable versioning
resource "aws_s3_bucket_versioning" "video_storage_versioning" {
  bucket = local.bucket_id
  versioning_configuration {
    status = "Enabled"
  }
}

# Enable server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "video_storage_encryption" {
  bucket = local.bucket_id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block public access
resource "aws_s3_bucket_public_access_block" "video_storage_public_access_block" {
  bucket = local.bucket_id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lambda function for video processing
resource "aws_lambda_function" "video_processor" {
  filename         = "lambda/video_processor.zip"
  function_name    = "${var.project_name}-${var.environment}-video-processor"
  role             = aws_iam_role.lambda_role.arn
  handler          = "video_processor.lambda_handler"
  runtime          = "python3.9"
  timeout          = 900

  environment {
    variables = {
      S3_BUCKET = local.bucket_id
    }
  }
}

# IAM role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-${var.environment}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM policy for Lambda to access S3 and CloudWatch Logs
resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project_name}-${var.environment}-lambda-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${local.bucket_id}",
          "arn:aws:s3:::${local.bucket_id}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.video_processor.function_name}"
  retention_in_days = 14
}

# Outputs
output "s3_bucket_name" {
  value = local.bucket_id
}

output "bucket_creation_status" {
  value = local.bucket_exists ? "Using existing bucket" : "Creating new bucket"
}