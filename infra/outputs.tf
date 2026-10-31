# Everything the Makefile, the scripts and the frontend build read: `terraform -chdir=infra output`.

# ---- auth
output "region" {
  value = var.region
}

output "user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "user_pool_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "cognito_domain" {
  description = "Cognito domain for OAuth redirects (Google)"
  value       = "${aws_cognito_user_pool_domain.main.domain}.auth.${var.region}.amazoncognito.com"
}

output "issuer" {
  description = "Issuer of the tokens; the backend checks it"
  value       = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
}

output "google_enabled" {
  value = local.has_google
}

# ---- reports
output "reports_bucket_name" {
  value = aws_s3_bucket.reports.bucket
}

output "report_requests_queue_url" {
  value = aws_sqs_queue.report_requests.url
}

output "report_requests_dlq_url" {
  value = aws_sqs_queue.report_requests_dlq.url
}

output "report_builder_function_name" {
  value = aws_lambda_function.report_builder.function_name
}

output "report_mailer_function_name" {
  value = aws_lambda_function.report_mailer.function_name
}

# ---- ai
output "parser_url" {
  description = "Function URL of the agenda parser, without the trailing slash"
  value       = trimsuffix(aws_lambda_function_url.agenda_parser.function_url, "/")
}

output "parser_function_name" {
  value = aws_lambda_function.agenda_parser.function_name
}

output "parser_log_group" {
  value = aws_cloudwatch_log_group.agenda_parser.name
}
