# Prevent Git Bash on Windows from converting arguments starting with / into Windows paths
export MSYS_NO_PATHCONV=1

# Shared setup for the infra scripts: credentials and settings come from .env via make.
: "${AWS_ACCESS_KEY_ID:?Set AWS_ACCESS_KEY_ID in .env}"
: "${AWS_SECRET_ACCESS_KEY:?Set AWS_SECRET_ACCESS_KEY in .env}"
: "${AWS_REGION:?Set AWS_REGION in .env}"
export AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""
[ -n "${AWS_SESSION_TOKEN:-}" ] || unset AWS_SESSION_TOKEN

# APP_NAME is the old name of the setting and still works.
PROJECT_NAME="${PROJECT_NAME:-${APP_NAME:-meetings}}"
ECR_STACK="$PROJECT_NAME-ecr"
BACKEND_STACK="$PROJECT_NAME-backend"
FRONTEND_STACK="$PROJECT_NAME-frontend"
# CloudFront only accepts certificates from us-east-1.
CERT_STACK="$PROJECT_NAME-certificate"
CERT_REGION="us-east-1"

# Every resource is tagged PROJECT_NAME=<PROJECT_NAME>: explicitly in the templates, via the
# stack tags (which also cover resources CloudFormation creates implicitly), and by the
# scripts for resources created outside CloudFormation.
TAG_KEY="PROJECT_NAME"
STACK_TAGS=("$TAG_KEY=$PROJECT_NAME")

# output STACK KEY [REGION]: prints one CloudFormation stack output (empty if absent).
output() {
  aws cloudformation describe-stacks --stack-name "$1" --region "${3:-$AWS_REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

# stack_exists STACK [REGION]
stack_exists() {
  aws cloudformation describe-stacks --stack-name "$1" --region "${2:-$AWS_REGION}" >/dev/null 2>&1
}

# cors_origins: the sites allowed to call the API: the CloudFront address and custom domain
# (once the frontend stack exists) plus CORS_ORIGINS_AWS.
cors_origins() {
  local candidates="" origins="" origin
  if stack_exists "$FRONTEND_STACK"; then
    candidates="$(output "$FRONTEND_STACK" AppUrl),$(output "$FRONTEND_STACK" CustomDomainUrl)"
  fi
  # Read line by line rather than word-splitting, so "*" (allow any origin) is not
  # expanded into file names.
  while IFS= read -r origin; do
    origin="${origin//[[:space:]]/}"
    [ -n "$origin" ] && origins="${origins:+$origins,}$origin"
  done < <(echo "$candidates,${CORS_ORIGINS_AWS:-}" | tr ',' '\n')
  echo "${origins:-http://localhost:5173}"
}

# update_backend_cors: points the backend's CORS_ORIGINS at the current frontend addresses.
# Every other backend parameter keeps its previous value.
update_backend_cors() {
  local origins
  origins="$(cors_origins)"
  echo "    CORS origins: $origins"
  aws cloudformation deploy \
    --stack-name "$BACKEND_STACK" \
    --template-file infra/backend.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides "CorsOrigins=$origins" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset
}

# Cognito, the reports and the agenda parser are Terraform now (infra/*.tf, applied by HCP
# Terraform). The scripts below read what they need from .env, or from AWS itself, so they
# need neither Terraform nor an HCP token (in CI as well).

# require_auth_settings: the user pool's IDs come from .env (COGNITO_*), as in CI. After a new
# pool: terraform -chdir=infra output user_pool_id / user_pool_client_id / cognito_domain.
require_auth_settings() {
  : "${COGNITO_USER_POOL_ID:?Set COGNITO_USER_POOL_ID in .env (terraform -chdir=infra output user_pool_id)}"
  : "${COGNITO_CLIENT_ID:?Set COGNITO_CLIENT_ID in .env (terraform -chdir=infra output user_pool_client_id)}"
  : "${COGNITO_DOMAIN:?Set COGNITO_DOMAIN in .env (terraform -chdir=infra output cognito_domain)}"
  COGNITO_GOOGLE_ENABLED="${COGNITO_GOOGLE_ENABLED:-false}"
}

# cognito_issuer: the issuer of the tokens, which the backend checks.
cognito_issuer() {
  echo "https://cognito-idp.$AWS_REGION.amazonaws.com/$COGNITO_USER_POOL_ID"
}

# parser_url: function URL of the agenda parser, without the trailing slash; empty if it is
# not deployed.
parser_url() {
  local url
  url="$(aws lambda get-function-url-config --function-name "$PROJECT_NAME-agenda-parser" \
    --query FunctionUrl --output text 2>/dev/null || true)"
  [ "$url" = "None" ] && url=""
  echo "${url%/}"
}

# remind_app_urls: Cognito's redirect URLs and the parser's CORS origins are the app_urls
# variable in infra/terraform.tfvars. If the frontend has an address that is not in there yet,
# say so: it changes through a pull request and an HCP Terraform run, not through this script.
remind_app_urls() {
  stack_exists "$FRONTEND_STACK" || return 0
  local url
  for url in "$(output "$FRONTEND_STACK" AppUrl)" "$(output "$FRONTEND_STACK" CustomDomainUrl)"; do
    [ -n "$url" ] && [ "$url" != "None" ] || continue
    grep -qF "\"$url\"" infra/terraform.tfvars 2>/dev/null || {
      echo "    NOTE: add \"$url\" to app_urls in infra/terraform.tfvars (pull request -> HCP Terraform)"
      echo "          so that Cognito may redirect back to it and the agenda parser accepts it."
    }
  done
}
