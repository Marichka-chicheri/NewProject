#!/usr/bin/env bash
# Step 3a of the Terraform migration: marks every resource of the auth, reports and ai stacks
# DeletionPolicy: Retain, redeploys the stacks with their previous parameters, and checks that
# CloudFormation really stored the policies. Nothing is deleted. Run it from the project root:
#     bash infra/migrate/retain.sh
set -euo pipefail

main() {
  cd "$(dirname "$0")/../.."
  set -a
  # shellcheck disable=SC1090
  [ -f .env ] && source <(tr -d '\r' <.env)
  set +a
  source infra/common.sh
  AUTH_STACK="$PROJECT_NAME-auth"
  REPORTS_STACK="$PROJECT_NAME-reports"
  AI_STACK="$PROJECT_NAME-ai"

  python3 infra/migrate/add_retain.py infra/auth.yaml infra/reports.yaml infra/ai.yml

  local pair stack file failed=0
  for pair in "$AUTH_STACK:infra/auth.yaml" "$REPORTS_STACK:infra/reports.yaml" "$AI_STACK:infra/ai.yml"; do
    stack="${pair%%:*}"
    file="${pair#*:}"
    stack_exists "$stack" || {
      echo "Stack $stack does not exist; skipping." >&2
      continue
    }
    echo "==> $stack"
    # No --parameter-overrides: every parameter keeps its previous value (including the secrets).
    # MIGRATION_TAG=1 adds a stack tag, which forces a real update if CloudFormation sees none.
    local tags=("${STACK_TAGS[@]}")
    [ "${MIGRATION_TAG:-}" = "1" ] && tags+=("Migration=terraform")
    aws cloudformation deploy \
      --stack-name "$stack" \
      --template-file "$file" \
      --capabilities CAPABILITY_IAM \
      --tags "${tags[@]}" \
      --no-fail-on-empty-changeset
    aws cloudformation get-template --stack-name "$stack" --template-stage Original \
      --query TemplateBody --output text | tr -d '\r' \
      | python3 infra/migrate/add_retain.py --verify "$file" || failed=1
  done

  if [ "$failed" = 1 ]; then
    echo
    echo "CloudFormation did not store the policies (it sees no change in a template that only" >&2
    echo "differs by DeletionPolicy). Run it again with a stack tag that forces an update:" >&2
    echo "  MIGRATION_TAG=1 bash infra/migrate/retain.sh" >&2
    exit 1
  fi
  echo
  echo "Done. Next: bash infra/migrate/imports.sh"
}

main "$@"
