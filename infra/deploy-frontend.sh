#!/usr/bin/env bash
# Builds the frontend against the backend's Lambda function URL and deploys it to
# S3 + CloudFront. Run via `make deploy-frontend` after `make deploy-backend`.
set -euo pipefail

# Everything runs inside main so bash parses the whole file before starting. Otherwise
# editing the script (or a git pull) during a long deploy makes bash resume mid-file.
main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  stack_exists "$BACKEND_STACK" || { echo "Stack $BACKEND_STACK not found; run make deploy-backend first." >&2; exit 1; }
  require_auth_settings
  api_base_url="$(output "$BACKEND_STACK" ApiBaseUrl)"
  # Paste an agenda is shown only when the parser exists (infra/ai.tf, applied by HCP Terraform).
  parser_url="$(parser_url)"

  echo "==> [1/6] Build the frontend (API: $api_base_url, parser: ${parser_url:-not deployed})"
  (cd frontend && npm ci && \
    VITE_API_URL="$api_base_url" \
    VITE_PARSER_URL="$parser_url" \
    COGNITO_USER_POOL_ID="$COGNITO_USER_POOL_ID" \
    COGNITO_CLIENT_ID="$COGNITO_CLIENT_ID" \
    COGNITO_DOMAIN="$COGNITO_DOMAIN" \
    COGNITO_GOOGLE_ENABLED="$COGNITO_GOOGLE_ENABLED" \
    npm run build)

  echo "==> [2/6] S3 bucket + CloudFront ($FRONTEND_STACK)"
  echo "    The first run creates the CloudFront distribution and takes about 5 minutes."
  # A custom domain added with `make add-domain` is kept: parameters that are not
  # overridden keep their previous values.
  aws cloudformation deploy \
    --stack-name "$FRONTEND_STACK" \
    --template-file infra/frontend.yaml \
    --parameter-overrides "ProjectName=$PROJECT_NAME" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset
  bucket="$(output "$FRONTEND_STACK" BucketName)"
  distribution="$(output "$FRONTEND_STACK" DistributionId)"

  echo "==> [3/6] Allow the frontend to call the API ($BACKEND_STACK)"
  update_backend_cors

  echo "==> [4/6] Cognito's redirect URLs (Terraform: app_urls in infra/terraform.tfvars)"
  remind_app_urls

  echo "==> [5/6] Upload to s3://$bucket"
  # Hashed assets never change, so browsers may cache them forever; everything else is revalidated.
  aws s3 sync frontend/dist/assets "s3://$bucket/assets" --delete \
    --cache-control "public, max-age=31536000, immutable"
  aws s3 sync frontend/dist "s3://$bucket" --delete --exclude "assets/*" \
    --cache-control "no-cache"

  echo "==> [6/6] Invalidate the CloudFront cache"
  # "/*" counts as a single path against the 1,000 free invalidation paths per month.
  invalidation="$(aws cloudfront create-invalidation --distribution-id "$distribution" \
    --paths "/*" --query Invalidation.Id --output text)"
  aws cloudfront wait invalidation-completed --distribution-id "$distribution" --id "$invalidation"

  echo
  echo "App: $(output "$FRONTEND_STACK" AppUrl)"
  custom_url="$(output "$FRONTEND_STACK" CustomDomainUrl)"
  [ -z "$custom_url" ] || echo "     $custom_url"
  echo "API: $api_base_url/api"
  if [ -n "${DOMAIN_NAME:-}" ] && [ "$custom_url" != "https://$DOMAIN_NAME" ]; then
    echo
    echo "DOMAIN_NAME=$DOMAIN_NAME in .env is not attached yet; run make add-domain."
  fi
}

main "$@"
