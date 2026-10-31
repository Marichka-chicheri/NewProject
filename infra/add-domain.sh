#!/usr/bin/env bash
# Attaches a custom domain to the deployed frontend: an ACM certificate in us-east-1,
# the domain as a CloudFront alias, and the domain in the backend's CORS origins.
# Run via `make add-domain` after `make deploy`; the domain comes from DOMAIN_NAME (and the
# optional Route 53 zone from HOSTED_ZONE_ID) in .env.
set -euo pipefail

# Everything runs inside main so bash parses the whole file before starting. Otherwise
# editing the script (or a git pull) during a long deploy makes bash resume mid-file.
main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  domain="${DOMAIN_NAME:-}"
  zone="${HOSTED_ZONE_ID:-}"
  [ -n "$domain" ] || { echo "Set DOMAIN_NAME (and optionally HOSTED_ZONE_ID) in .env first." >&2; exit 1; }
  for stack in "$BACKEND_STACK" "$FRONTEND_STACK"; do
    stack_exists "$stack" || { echo "Stack $stack not found; run make deploy first." >&2; exit 1; }
  done
  if stack_exists "$CERT_STACK" "$CERT_REGION"; then
    current="$(aws cloudformation describe-stacks --stack-name "$CERT_STACK" --region "$CERT_REGION" \
      --query "Stacks[0].Parameters[?ParameterKey=='DomainName'].ParameterValue" --output text)"
    if [ "$current" != "$domain" ]; then
      echo "The app already uses $current; run make remove-domain first, then make add-domain." >&2
      exit 1
    fi
  fi

  echo "==> [1/3] Certificate for $domain ($CERT_STACK in $CERT_REGION)"
  # Runs in the background: without Route 53 the stack waits until the validation record
  # exists, and that record is only known once the certificate has been requested.
  aws cloudformation deploy \
    --stack-name "$CERT_STACK" \
    --region "$CERT_REGION" \
    --template-file infra/certificate.yaml \
    --parameter-overrides "ProjectName=$PROJECT_NAME" "DomainName=$domain" "HostedZoneId=$zone" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset >/dev/null &
  deploy_pid=$!

  shown=""
  while kill -0 "$deploy_pid" 2>/dev/null; do
    if [ -z "$shown" ]; then
      arn="$(aws cloudformation describe-stack-resource --stack-name "$CERT_STACK" --region "$CERT_REGION" \
        --logical-resource-id Certificate --query StackResourceDetail.PhysicalResourceId \
        --output text 2>/dev/null || true)"
      if [[ "$arn" == arn:* ]]; then
        record="$(aws acm describe-certificate --certificate-arn "$arn" --region "$CERT_REGION" \
          --query "Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Type,Value]" \
          --output text 2>/dev/null || true)"
        if [ -n "$record" ] && [ "$record" != "None" ]; then
          read -r rec_name rec_type rec_value <<<"$record"
          if [ -n "$zone" ]; then
            echo "    Route 53 validation record is created automatically; waiting for ACM..."
          else
            echo "    Add this DNS record at your DNS provider, then wait (usually a few minutes):"
            echo "      $rec_type  $rec_name  ->  $rec_value"
          fi
          shown=1
        fi
      fi
    fi
    sleep 10
  done
  wait "$deploy_pid"
  cert_arn="$(output "$CERT_STACK" CertificateArn "$CERT_REGION")"
  echo "    Issued: $cert_arn"

  echo "==> [2/3] Add $domain to CloudFront ($FRONTEND_STACK)"
  aws cloudformation deploy \
    --stack-name "$FRONTEND_STACK" \
    --template-file infra/frontend.yaml \
    --parameter-overrides "DomainName=$domain" "CertificateArn=$cert_arn" "HostedZoneId=$zone" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset

  echo "==> [3/3] Allow https://$domain to call the API ($BACKEND_STACK)"
  update_backend_cors
  remind_app_urls

  echo
  if [ -z "$zone" ]; then
    echo "Point the domain at CloudFront at your DNS provider:"
    echo "  CNAME  $domain  ->  $(output "$FRONTEND_STACK" DistributionDomain)"
    echo "(An apex domain like example.com needs ALIAS/ANAME support, or Route 53 via HOSTED_ZONE_ID)"
  fi
  echo "App: https://$domain"
}

main "$@"
