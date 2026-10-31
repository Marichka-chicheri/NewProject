#!/usr/bin/env bash
# Detaches the custom domain from the frontend and deletes its certificate.
# Run via `make remove-domain`. The app stays available at its *.cloudfront.net address.
set -euo pipefail

# Everything runs inside main so bash parses the whole file before starting. Otherwise
# editing the script (or a git pull) during a long deploy makes bash resume mid-file.
main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  stack_exists "$FRONTEND_STACK" || { echo "Stack $FRONTEND_STACK not found." >&2; exit 1; }

  echo "==> [1/3] Remove the domain from CloudFront ($FRONTEND_STACK)"
  aws cloudformation deploy \
    --stack-name "$FRONTEND_STACK" \
    --template-file infra/frontend.yaml \
    --parameter-overrides "DomainName=" "CertificateArn=" "HostedZoneId=" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset

  echo "==> [2/3] Update the API's CORS origins"
  if stack_exists "$BACKEND_STACK"; then
    update_backend_cors
  fi
  echo "    Cognito's redirect URLs: remove the domain from app_urls in infra/terraform.tfvars."

  echo "==> [3/3] Delete the certificate ($CERT_STACK in $CERT_REGION)"
  if stack_exists "$CERT_STACK" "$CERT_REGION"; then
    aws cloudformation delete-stack --stack-name "$CERT_STACK" --region "$CERT_REGION"
    aws cloudformation wait stack-delete-complete --stack-name "$CERT_STACK" --region "$CERT_REGION"
  fi

  echo
  echo "Done. Remove the domain's DNS records at your DNS provider if you added them yourself."
  echo "App: $(output "$FRONTEND_STACK" AppUrl)"
}

main "$@"
