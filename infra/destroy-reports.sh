#!/usr/bin/env bash
# Deletes the reports infrastructure stack.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  stack_exists "$REPORTS_STACK" || {
    echo "Stack $REPORTS_STACK does not exist."
    exit 0
  }

  echo "==> Deleting $REPORTS_STACK stack"
  bucket="$(output "$REPORTS_STACK" ReportsBucketName)"
  if [ -n "$bucket" ] && [ "$bucket" != "None" ]; then
    echo "    Emptying S3 bucket s3://$bucket"
    aws s3 rm "s3://$bucket" --recursive || true
  fi

  aws cloudformation delete-stack --stack-name "$REPORTS_STACK"
  echo "    Waiting for stack deletion to complete..."
  aws cloudformation wait stack-delete-complete --stack-name "$REPORTS_STACK"
  echo "    Deleted $REPORTS_STACK"
}

main "$@"
