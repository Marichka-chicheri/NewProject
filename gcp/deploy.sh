#!/usr/bin/env bash
# Deploys the code to GCP after `terraform apply` in gcp/ has created the infrastructure:
#   1. builds the backend image (default target: no Lambda Web Adapter, listens on $PORT),
#   2. pushes it to Artifact Registry and points the Cloud Run service at it,
#   3. builds the frontend with an empty VITE_API_URL (same origin: Firebase Hosting rewrites
#      /api/** to Cloud Run) and deploys it to Firebase Hosting.
#
# Needs: gcloud (gcloud auth login + gcloud auth application-default login), Docker, Node.js,
# Terraform (terraform login, terraform init in gcp/). No service account key anywhere.
#
#   bash gcp/deploy.sh
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."

  tf() { terraform -chdir=gcp "$@"; }
  project="$(sed -nE 's/^project_id *= *"(.*)"/\1/p' gcp/terraform.tfvars)"
  region="$(sed -nE 's/^region *= *"(.*)"/\1/p' gcp/terraform.tfvars)"
  repository="$(tf output -raw image_repository)"
  service="$(tf output -raw api_service)"
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
  image="$repository/backend:$tag"

  echo "==> [1/3] Build and push $image"
  gcloud auth configure-docker "$region-docker.pkg.dev" --quiet
  # Cloud Run runs x86_64; the AWS build is arm64 with --target lambda.
  docker build --target app --platform linux/amd64 --provenance=false --tag "$image" backend
  docker push "$image"

  echo "==> [2/3] Cloud Run $service -> $tag"
  gcloud run services update "$service" --project "$project" --region "$region" \
    --image "$image" --quiet
  api_url="$(gcloud run services describe "$service" --project "$project" --region "$region" \
    --format 'value(status.url)')"
  curl -fsS --max-time 60 "$api_url/api/health" && echo

  echo "==> [3/3] Frontend -> Firebase Hosting ($app_url)"
  (cd frontend && npm ci && \
    VITE_API_URL="" \
    VITE_PARSER_URL="${VITE_PARSER_URL:-}" \
    COGNITO_USER_POOL_ID="$COGNITO_USER_POOL_ID" \
    COGNITO_CLIENT_ID="$COGNITO_CLIENT_ID" \
    COGNITO_DOMAIN="${COGNITO_DOMAIN:-}" \
    COGNITO_GOOGLE_ENABLED="${COGNITO_GOOGLE_ENABLED:-false}" \
    npm run build && \
    npx --yes firebase-tools@14 deploy --only hosting --project "$project" --non-interactive)

  echo
  echo "App:    $app_url"
  echo "Health: $app_url/api/health (through the rewrite), $api_url/api/health (direct)"
}

main "$@"
