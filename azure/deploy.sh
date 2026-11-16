#!/usr/bin/env bash
# Deploys the code to Azure after `terraform apply` in azure/ has created the infrastructure:
#   1. builds the backend image (default target: no Lambda Web Adapter, listens on $PORT),
#   2. pushes it to Azure Container Registry and points the Container App at it,
#   3. builds the frontend with VITE_API_URL = the Container App's URL and uploads it to
#      Static Web Apps.
#
# Needs: Azure CLI (`az login`), Docker, Node.js, Terraform (`terraform login`, `terraform init`
# in azure/). No client secret or key is stored: az uses your login, the API uses a managed
# identity. The Static Web Apps deployment token is read from Azure for this one run only.
#
#   bash azure/deploy.sh
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."

  tf() { terraform -chdir=azure "$@"; }
  group="$(tf output -raw resource_group)"
  registry="$(tf output -raw registry)"
  login_server="$(tf output -raw registry_login_server)"
  app="$(tf output -raw api_app)"
  swa="$(tf output -raw static_web_app)"
  api_url="$(tf output -raw api_url)"
  app_url="$(tf output -raw app_url)"

  # Public Cognito ids for the frontend bundle (sign-in stays on AWS): from the repo's .env.
  if [ -f .env ]; then
    set -a; source .env; set +a
  fi
  : "${COGNITO_USER_POOL_ID:?set COGNITO_USER_POOL_ID in .env (make infra-output)}"
  : "${COGNITO_CLIENT_ID:?set COGNITO_CLIENT_ID in .env}"

  tag="$(git rev-parse --short HEAD)"
  if [ -n "$(git status --porcelain -- backend)" ]; then
    tag="$tag-dirty-$(date +%Y%m%d%H%M%S)"
  fi
  image="$login_server/spry-backend:$tag"

  echo "==> [1/3] Build and push $image"
  az acr login --name "$registry"
  # Container Apps run x86_64; the AWS build is arm64 with --target lambda.
  docker build --target app --platform linux/amd64 --provenance=false --tag "$image" backend
  docker push "$image"

  echo "==> [2/3] Container App $app -> $tag"
  az containerapp update --name "$app" --resource-group "$group" --image "$image" >/dev/null
  # The first request after scale-to-zero waits for a cold start (container + migrations).
  for _ in $(seq 24); do
    if curl -fsS --max-time 30 "$api_url/api/health"; then echo; break; fi
    sleep 5
  done

  echo "==> [3/3] Frontend -> Static Web Apps ($app_url)"
  token="$(az staticwebapp secrets list --name "$swa" --resource-group "$group" \
    --query properties.apiKey -o tsv)"
  (cd frontend && npm ci && \
    VITE_API_URL="$api_url" \
    VITE_PARSER_URL="${VITE_PARSER_URL:-}" \
    COGNITO_USER_POOL_ID="$COGNITO_USER_POOL_ID" \
    COGNITO_CLIENT_ID="$COGNITO_CLIENT_ID" \
    COGNITO_DOMAIN="${COGNITO_DOMAIN:-}" \
    COGNITO_GOOGLE_ENABLED="${COGNITO_GOOGLE_ENABLED:-false}" \
    npm run build && \
    SWA_CLI_DEPLOYMENT_TOKEN="$token" \
    npx --yes @azure/static-web-apps-cli@2 deploy ./dist --env production)

  echo
  echo "App:    $app_url"
  echo "Health: $api_url/api/health"
}

main "$@"
