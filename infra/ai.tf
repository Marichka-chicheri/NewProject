# Paste an agenda (Lab 6): the agenda-parser Lambda runs outside the VPC (it needs no database),
# reuses the backend's container image with another handler and calls Amazon Bedrock over the
# internet: no NAT gateway, no VPC endpoint, nothing to pay while nobody uses it. Its function
# URL is public, but the handler requires a Cognito ID token. Also a monthly AWS Budgets alarm
# for the whole account. Was infra/ai.yml.
#
# The user pool and the app client come straight from auth.tf; no more copying IDs between stacks.

resource "aws_cloudwatch_log_group" "agenda_parser" {
  name              = "/${var.project_name}/agenda-parser"
  retention_in_days = 14
}

resource "aws_iam_role" "agenda_parser" {
  name = "${var.project_name}-agenda-parser"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# CloudWatch Logs only: no VPC, no database, no S3.
resource "aws_iam_role_policy_attachment" "agenda_parser_logs" {
  role       = aws_iam_role.agenda_parser.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "agenda_parser" {
  name = "CallClaudeOnBedrock"
  role = aws_iam_role.agenda_parser.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The Anthropic Messages API on Bedrock (bedrock-mantle). "*" for now; see
        # docs/adr/0006-llm-agenda-parsing.md on narrowing it.
        Effect   = "Allow"
        Action   = "bedrock-mantle:CreateInference"
        Resource = "*"
      },
      {
        # Amazon Nova through the Converse API. A us.* inference profile may route the call to
        # us-east-1, us-east-2 or us-west-2, so the model ARNs of all three apply.
        Effect = "Allow"
        Action = "bedrock:InvokeModel"
        Resource = [
          "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/*",
          "arn:aws:bedrock:*::foundation-model/*",
        ]
      },
    ]
  })
}

resource "aws_lambda_function" "agenda_parser" {
  function_name = "${var.project_name}-agenda-parser"
  description   = "Paste an agenda - pasted text in, agenda JSON out (Amazon Bedrock)"
  package_type  = "Image"
  image_uri     = data.aws_lambda_function.backend.image_uri
  architectures = ["arm64"]
  memory_size   = 512
  timeout       = 30
  role          = aws_iam_role.agenda_parser.arn

  image_config {
    command = ["app.ai.agenda_lambda.handler"]
  }

  # No vpc_config: the function reaches Bedrock and Cognito over the internet.

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.agenda_parser.name
  }

  environment {
    variables = {
      PARSER_MODEL         = var.parser_model
      PARSER_MAX_CHARS     = "10000"
      COGNITO_USER_POOL_ID = aws_cognito_user_pool.main.id
      COGNITO_CLIENT_ID    = aws_cognito_user_pool_client.web.id
      # Same as the report builder: the handler runs its own runtime loop, not uvicorn.
      AWS_LWA_ASYNC_INIT = "false"
    }
  }

  # The image follows every backend build (infra/update-lambdas.sh); see reports.tf.
  lifecycle {
    ignore_changes = [image_uri]
  }

  depends_on = [aws_iam_role_policy_attachment.agenda_parser_logs, aws_iam_role_policy.agenda_parser]
}

resource "aws_lambda_function_url" "agenda_parser" {
  function_name      = aws_lambda_function.agenda_parser.function_name
  authorization_type = "NONE"

  # The function URL answers the browser's preflight and adds the CORS headers itself.
  cors {
    allow_origins = var.app_urls
    allow_methods = ["POST"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 3600
  }
}

# Public, as the API in Lab 4: both permissions are needed. The handler checks the token.
resource "aws_lambda_permission" "agenda_parser_url" {
  statement_id           = "AllowPublicFunctionUrl"
  function_name          = aws_lambda_function.agenda_parser.function_name
  action                 = "lambda:InvokeFunctionUrl"
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "agenda_parser_invoke" {
  statement_id             = "AllowPublicInvokeViaFunctionUrl"
  function_name            = aws_lambda_function.agenda_parser.function_name
  action                   = "lambda:InvokeFunction"
  principal                = "*"
  invoked_via_function_url = true
}

# The cheapest insurance in the course: an email when the month's bill passes the limit (actual)
# or is forecast to (forecasted). It covers the whole account, not only these resources.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.project_name}-monthly"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"

  notification {
    notification_type          = "ACTUAL"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    notification_type          = "FORECASTED"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_email]
  }
}
