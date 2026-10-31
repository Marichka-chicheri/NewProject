variable "project_name" {
  type        = string
  description = "Prefix of every resource name and the value of the PROJECT_NAME tag (PROJECT_NAME in .env)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.project_name))
    error_message = "project_name must be lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# ---------------------------------------------------------------- auth (was infra/auth.yaml)

variable "app_urls" {
  type        = list(string)
  description = <<-EOT
    Origins of the frontend, without a trailing slash: the local dev servers, the CloudFront
    address and the custom domain. Cognito redirects back to <origin>/login (OAuth, Google), and
    the agenda parser accepts browser calls from these origins. After the first
    `make deploy-frontend` or `make add-domain`, add the new address here in a pull request.
  EOT
}

variable "google_client_id" {
  type        = string
  default     = ""
  description = "Google OAuth client id; empty keeps Google sign-in disabled. Not a secret."
}

variable "google_client_secret" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Google OAuth client secret. Set it as a sensitive variable in the HCP Terraform workspace, never in a file."
}

# ------------------------------------------------------------- reports (was infra/reports.yaml)

variable "reports_sender_email" {
  type        = string
  description = "Verified SES identity the weekly report is sent from."
}

variable "reports_recipient_email" {
  type        = string
  description = "Recipient(s) of the weekly report, comma-separated."
}

variable "schedule_cron" {
  type        = string
  default     = "cron(0 7 ? * MON *)"
  description = "EventBridge Scheduler expression (default: Mondays at 07:00)."
}

variable "schedule_timezone" {
  type    = string
  default = "Europe/Kyiv"
}

variable "lambda_memory" {
  type        = number
  default     = 512
  description = "Memory of the report builder, in MB."
}

variable "lambda_timeout" {
  type        = number
  default     = 60
  description = "Timeout of the report builder, in seconds. The queue's visibility timeout is 6x this."
}

# ------------------------------------------------------------------ ai (was infra/ai.yml)

variable "parser_model" {
  type        = string
  default     = "us.amazon.nova-lite-v1:0"
  description = "Bedrock model ID of the agenda parser: anthropic.* uses the Messages API, anything else (Amazon Nova) the Converse API."
}

variable "budget_email" {
  type        = string
  description = "Where the AWS Budgets alarm is sent."
}

variable "budget_limit_usd" {
  type    = number
  default = 5
}
