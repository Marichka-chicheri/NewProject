# Cognito: sign-in with email and password (self sign-up, email verification code), a public app
# client for the SPA, a hosted domain for OAuth, and Google as an identity provider that exists
# only when google_client_id is set. Was infra/auth.yaml (Lab 4).

locals {
  # Allow <origin>/login, <origin>/login/ and <origin>/ for every origin.
  oauth_urls = flatten([for origin in var.app_urls : ["${origin}/login", "${origin}/login/", "${origin}/"]])

  has_google = var.google_client_id != ""
}

# Deleting or replacing the pool deletes every account in it, so Terraform refuses to destroy it:
# a plan that wants to is an error, not a question.
resource "aws_cognito_user_pool" "main" {
  name           = "${var.project_name}-users"
  user_pool_tier = "ESSENTIALS"

  # Users sign in with their email; Cognito emails a code to verify it.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  username_configuration {
    case_sensitive = false
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  # A new email (profile page) takes effect only after its code is entered; until then the user
  # keeps signing in with, and recovering the password through, the old one.
  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = "0"
      max_length = "2048"
    }
  }

  schema {
    name                = "name"
    attribute_data_type = "String"
    required            = false
    mutable             = true

    string_attribute_constraints {
      min_length = "0"
      max_length = "2048"
    }
  }

  # Mirrored by the signup form (frontend/src/pages/signup-page.tsx).
  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_uppercase = false
    require_symbols   = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Cognito's own sender: no SES setup, limited to about 50 emails a day.
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Your Meetings verification code"
    email_message        = "Your Meetings verification code is {####}"
  }

  lifecycle {
    prevent_destroy = true

    # The schema of a pool cannot be changed after it is created, and Cognito reports the
    # standard attributes in its own way, so Terraform would try to "add" them again. The blocks
    # above document (and, for a new pool, create) the schema; they are not compared afterwards.
    ignore_changes = [schema]
  }
}

# Hosted domain for the OAuth endpoints (needed for Google and Managed Login). Prefixes are global.
resource "aws_cognito_user_pool_domain" "main" {
  domain                = "${var.project_name}-${data.aws_caller_identity.current.account_id}"
  user_pool_id          = aws_cognito_user_pool.main.id
  managed_login_version = 2
}

resource "aws_cognito_managed_login_branding" "main" {
  user_pool_id                = aws_cognito_user_pool.main.id
  client_id                   = aws_cognito_user_pool_client.web.id
  use_cognito_provided_values = true

  depends_on = [aws_cognito_user_pool_domain.main]
}

resource "aws_cognito_identity_provider" "google" {
  count = local.has_google ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.main.id
  provider_name = "Google"
  provider_type = "Google"

  # Cognito fills in the endpoints of a Google provider itself; they are listed so that the plan
  # matches what the API returns.
  provider_details = {
    client_id                     = var.google_client_id
    client_secret                 = var.google_client_secret
    authorize_scopes              = "openid email profile"
    attributes_url                = "https://people.googleapis.com/v1/people/me?personFields="
    attributes_url_add_attributes = "true"
    authorize_url                 = "https://accounts.google.com/o/oauth2/v2/auth"
    oidc_issuer                   = "https://accounts.google.com"
    token_request_method          = "POST"
    token_url                     = "https://www.googleapis.com/oauth2/v4/token"
  }

  attribute_mapping = {
    email          = "email"
    email_verified = "email_verified"
    name           = "name"
    username       = "sub"
  }
}

# Public client (no secret): the SPA talks to Cognito directly with SRP.
resource "aws_cognito_user_pool_client" "web" {
  user_pool_id = aws_cognito_user_pool.main.id
  name         = "${var.project_name}-web"

  # No generate_secret: a public client has none, and setting it (even to false) would make
  # Terraform replace the imported client, which changes its ID and breaks sign-in.
  explicit_auth_flows           = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  # Referencing the provider makes the client wait for it.
  supported_identity_providers = concat(["COGNITO"], aws_cognito_identity_provider.google[*].provider_name)

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  callback_urls                        = local.oauth_urls
  logout_urls                          = local.oauth_urls
}
