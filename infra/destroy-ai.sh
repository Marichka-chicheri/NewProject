#!/usr/bin/env bash
# Deletes the agenda parser stack (and with it the budget alarm).
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  stack_exists "$AI_STACK" || {
    echo "Stack $AI_STACK does not exist."
    exit 0
  }
  echo "==> Deleting $AI_STACK"
  aws cloudformation delete-stack --stack-name "$AI_STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$AI_STACK"
  echo "    Deleted $AI_STACK"
}

main "$@"
