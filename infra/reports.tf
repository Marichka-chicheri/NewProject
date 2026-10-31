# Weekly meetings report: EventBridge Scheduler -> SQS (+ DLQ) -> report-builder Lambda in the
# VPC -> private S3 bucket -> report-mailer Lambda outside the VPC -> Amazon SES.
# Was infra/reports.yaml (Lab 5).
#
# Lab 5's circular dependency (bucket -> notification -> Lambda permission -> bucket) is gone: the
# bucket, the Lambda permission and the bucket notification are three separate resources.

locals {
  reports_bucket_name = "${var.project_name}-reports-${data.aws_caller_identity.current.account_id}"
}

# The VPC, the private subnets and the database belong to the backend, which is still
# CloudFormation (infra/backend.yaml). Read its outputs instead of copying them.
data "aws_cloudformation_stack" "backend" {
  name = "${var.project_name}-backend"
}

data "aws_lambda_function" "backend" {
  function_name = "${var.project_name}-backend"
}

data "aws_ssm_parameter" "db_password" {
  name = "/${var.project_name}/db-password"
}

data "aws_route_tables" "backend_vpc" {
  vpc_id = data.aws_cloudformation_stack.backend.outputs["VpcId"]
}

locals {
  backend = data.aws_cloudformation_stack.backend.outputs

  database_url = "postgresql+asyncpg://meetings:${data.aws_ssm_parameter.db_password.value}@${local.backend["DatabaseEndpoint"]}:5432/meetings"
}

# ----------------------------------------------------------------------------- S3

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = local.backend["VpcId"]
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = tolist(data.aws_route_tables.backend_vpc.ids)
}

resource "aws_s3_bucket" "reports" {
  bucket = local.reports_bucket_name

  # Every report is in here: Terraform refuses to destroy the bucket.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "DeleteReportsAfter90Days"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_notification" "reports" {
  bucket = aws_s3_bucket.reports.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.report_mailer.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "reports/"
    filter_suffix       = ".csv"
  }

  # S3 checks that it may invoke the function when the notification is saved.
  depends_on = [aws_lambda_permission.report_mailer_s3]
}

# ----------------------------------------------------------------------------- SQS

resource "aws_sqs_queue" "report_requests_dlq" {
  name                      = "${var.project_name}-report-requests-dlq"
  message_retention_seconds = 1209600 # 14 days
  max_message_size          = 1048576 # what AWS gives new queues today (the provider's default is 256 KiB)
}

resource "aws_sqs_queue" "report_requests" {
  name             = "${var.project_name}-report-requests"
  max_message_size = 1048576

  # At least 6x the builder's timeout.
  visibility_timeout_seconds = 6 * var.lambda_timeout

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.report_requests_dlq.arn
    maxReceiveCount     = 3
  })
}

# ------------------------------------------------------------ EventBridge Scheduler

resource "aws_iam_role" "scheduler" {
  name = "${var.project_name}-report-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "SendMessageToSQS"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.report_requests.arn
    }]
  })
}

resource "aws_scheduler_schedule" "weekly_report" {
  name                         = "${var.project_name}-weekly-report"
  schedule_expression          = var.schedule_cron
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sqs_queue.report_requests.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = "{\"week\": null, \"source\": \"schedule\"}"
  }
}

# ------------------------------------------------------------------ report builder

resource "aws_cloudwatch_log_group" "report_builder" {
  name              = "/${var.project_name}/report-builder"
  retention_in_days = 7
}

resource "aws_iam_role" "report_builder" {
  name = "${var.project_name}-report-builder"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "report_builder_vpc" {
  role       = aws_iam_role.report_builder.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "report_builder" {
  name = "S3AndSQSPermissions"
  role = aws_iam_role.report_builder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.reports.arn}/reports/*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.report_requests.arn
      },
    ]
  })
}

resource "aws_lambda_function" "report_builder" {
  function_name = "${var.project_name}-report-builder"
  package_type  = "Image"
  image_uri     = data.aws_lambda_function.backend.image_uri
  architectures = ["arm64"]
  memory_size   = var.lambda_memory
  timeout       = var.lambda_timeout
  role          = aws_iam_role.report_builder.arn

  image_config {
    command = ["app.reports.lambda_handler.handler"]
  }

  vpc_config {
    subnet_ids         = [local.backend["PrivateSubnetA"], local.backend["PrivateSubnetB"]]
    security_group_ids = [local.backend["FunctionSecurityGroup"]]
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.report_builder.name
  }

  environment {
    variables = {
      DATABASE_URL   = local.database_url
      REPORTS_BUCKET = local.reports_bucket_name
      # Avoid Lambda Web Adapter intercepting standard invocation.
      AWS_LWA_ASYNC_INIT = "false"
    }
  }

  # The image is the backend's: the pipeline (GitHub Actions, infra/update-lambdas.sh) moves it
  # to every new backend build. Terraform owns the function's shape, not the code it runs.
  lifecycle {
    ignore_changes = [image_uri]
  }

  depends_on = [aws_iam_role_policy_attachment.report_builder_vpc, aws_iam_role_policy.report_builder]
}

resource "aws_lambda_event_source_mapping" "report_builder" {
  event_source_arn = aws_sqs_queue.report_requests.arn
  function_name    = aws_lambda_function.report_builder.arn
  batch_size       = 1
  enabled          = true
}

# ------------------------------------------------------------------- report mailer

resource "aws_cloudwatch_log_group" "report_mailer" {
  name              = "/${var.project_name}/report-mailer"
  retention_in_days = 7
}

resource "aws_iam_role" "report_mailer" {
  name = "${var.project_name}-report-mailer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "report_mailer_logs" {
  role       = aws_iam_role.report_mailer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "report_mailer" {
  name = "MailerPermissions"
  role = aws_iam_role.report_mailer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.reports.arn}/reports/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
      },
    ]
  })
}

# The code is small enough to live in the repository (infra/lambda/report_mailer.py).
data "archive_file" "report_mailer" {
  type        = "zip"
  output_path = "${path.module}/.terraform/report_mailer.zip"

  source {
    content  = file("${path.module}/lambda/report_mailer.py")
    filename = "index.py"
  }
}

resource "aws_lambda_function" "report_mailer" {
  function_name    = "${var.project_name}-report-mailer"
  runtime          = "python3.12"
  handler          = "index.handler"
  memory_size      = 256
  timeout          = 30
  role             = aws_iam_role.report_mailer.arn
  filename         = data.archive_file.report_mailer.output_path
  source_code_hash = data.archive_file.report_mailer.output_base64sha256

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.report_mailer.name
  }

  environment {
    variables = {
      SENDER_EMAIL    = var.reports_sender_email
      RECIPIENT_EMAIL = var.reports_recipient_email
    }
  }

  depends_on = [aws_iam_role_policy_attachment.report_mailer_logs, aws_iam_role_policy.report_mailer]
}

resource "aws_lambda_permission" "report_mailer_s3" {
  statement_id   = "AllowReportsBucket"
  function_name  = aws_lambda_function.report_mailer.function_name
  action         = "lambda:InvokeFunction"
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.reports.arn
  source_account = data.aws_caller_identity.current.account_id
}
