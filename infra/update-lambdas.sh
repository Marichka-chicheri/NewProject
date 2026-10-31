#!/usr/bin/env bash
# Points the report builder and the agenda parser at the image the backend function runs now.
# Run via `make update-lambdas` and by CI after every backend deploy.
#
# Terraform owns the shape of these functions (role, memory, environment, VPC) but not the code
# they run: their image_uri is ignore_changes in infra/reports.tf and infra/ai.tf. The pipeline
# moves the image, HCP Terraform moves the infrastructure. When a change needs both, for example
# a new environment variable: merge the Terraform pull request first (the code must tolerate the
# variable being absent for a few minutes), then deploy the code that reads it.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  image="$(aws lambda get-function --function-name "$PROJECT_NAME-backend" \
    --query Code.ImageUri --output text)"
  echo "==> Backend image: $image"

  for name in report-builder agenda-parser; do
    function="$PROJECT_NAME-$name"
    if aws lambda get-function --function-name "$function" >/dev/null 2>&1; then
      echo "    $function"
      aws lambda update-function-code --function-name "$function" --image-uri "$image" \
        --query LastUpdateStatus --output text
      aws lambda wait function-updated --function-name "$function"
    else
      echo "    $function does not exist yet (infra/ is applied by HCP Terraform); skipping"
    fi
  done
}

main "$@"
