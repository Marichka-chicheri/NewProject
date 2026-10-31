#!/usr/bin/env bash
# Deploys the agenda parser (Lambda outside the VPC + public function URL) and the monthly
# budget alarm via `make deploy-ai`. Run after `make deploy-backend`: the parser reuses the
# image currently deployed on the backend function. Then `make deploy-frontend` builds the
# frontend against the parser's URL.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  require_auth_stack
  stack_exists "$BACKEND_STACK" || {
    echo "Stack $BACKEND_STACK not found; run make deploy-backend first." >&2
    exit 1
  }

  image="$(aws lambda get-function --function-name "$PROJECT_NAME-backend" \
    --query Code.ImageUri --output text)"
  pool_id="$(output "$AUTH_STACK" UserPoolId)"
  client_id="$(output "$AUTH_STACK" UserPoolClientId)"
  # The deployed sites plus the local dev servers, so the parser can be tried from `make dev-*`.
  cors="$(cors_origins),http://localhost:5173,http://localhost:3000"
  model="${PARSER_MODEL:-us.amazon.nova-lite-v1:0}"
  budget_email="${BUDGET_EMAIL:-${REPORTS_RECIPIENT_EMAIL:-}}"
  [ -n "$budget_email" ] || {
    echo "Set BUDGET_EMAIL (or REPORTS_RECIPIENT_EMAIL) in .env for the budget alarm." >&2
    exit 1
  }

  echo "==> Deploying '$PROJECT_NAME' agenda parser to $AWS_REGION ($AI_STACK)"
  echo "    Image: $image"
  echo "    Model: $model"
  echo "    Cognito: $pool_id (client $client_id)"
  echo "    CORS origins: $cors"
  echo "    Budget alarm: 5 USD a month -> $budget_email"

  aws cloudformation deploy \
    --stack-name "$AI_STACK" \
    --template-file infra/ai.yml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
      "ProjectName=$PROJECT_NAME" \
      "ImageUri=$image" \
      "ParserModel=$model" \
      "CognitoUserPoolId=$pool_id" \
      "CognitoClientId=$client_id" \
      "CorsOrigins=$cors" \
      "BudgetEmail=$budget_email" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset

  echo
  echo "Parser: $(output "$AI_STACK" ParserUrl)"
  echo "Logs:   aws logs tail $(output "$AI_STACK" ParserLogGroup) --follow"
  echo "Next:   make deploy-frontend (builds the frontend against this URL)"
}

main "$@"
