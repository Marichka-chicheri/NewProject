#!/usr/bin/env bash
# Step 3b: writes infra/imports.tf with the real IDs of the resources, while the stacks still
# exist. Run from the project root:   bash infra/migrate/imports.sh
set -euo pipefail

main() {
  cd "$(dirname "$0")/../.."
  set -a
  # shellcheck disable=SC1090
  [ -f .env ] && source <(tr -d '\r' <.env)
  set +a
  source infra/common.sh
  # The AWS CLI runs here (in bash); Python only reads what it saved.
  dump=infra/migrate/.dump
  mkdir -p "$dump"
  trap 'rm -rf "$dump"' EXIT
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  export ACCOUNT_ID
  for suffix in auth reports ai; do
    aws cloudformation list-stack-resources --stack-name "$PROJECT_NAME-$suffix" --output json \
      >"$dump/$PROJECT_NAME-$suffix.json"
  done
  DUMP_DIR="$dump" python3 infra/migrate/make_imports.py
  echo
  echo "Next: check infra/imports.tf, then delete the three stacks (docs/lab7-migration.md, step 5)."
}

main "$@"
