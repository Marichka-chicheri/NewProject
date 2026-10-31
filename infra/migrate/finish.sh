#!/usr/bin/env bash
# Step 3d, after `terraform plan` said "No changes": deletes what the migration left behind and
# removes the CloudFormation files from the repository (git rm). Run from the project root:
#     bash infra/migrate/finish.sh
# It asks before it deletes anything.
set -euo pipefail

main() {
  cd "$(dirname "$0")/../.."
  set -a
  # shellcheck disable=SC1090
  [ -f .env ] && source <(tr -d '\r' <.env)
  set +a
  source infra/common.sh

  echo "This deletes the IAM roles CloudFormation created for the reports and the parser"
  echo "(Terraform now has its own, explicitly named ones) and removes the old templates,"
  echo "scripts from git."
  read -r -p "Did the HCP Terraform apply finish and does a new plan say 'No changes'? [yes/no] " answer
  [ "$answer" = "yes" ] || { echo "Aborted."; exit 1; }

  if [ -f infra/migrate/old-roles.txt ]; then
    while IFS= read -r role; do
      [ -n "$role" ] || continue
      echo "==> Deleting old role $role"
      for arn in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
        aws iam detach-role-policy --role-name "$role" --policy-arn "$arn"
      done
      for name in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null); do
        aws iam delete-role-policy --role-name "$role" --policy-name "$name"
      done
      aws iam delete-role --role-name "$role" || echo "    could not delete $role (already gone?)" >&2
    done <infra/migrate/old-roles.txt
  fi

  git rm -rf --ignore-unmatch \
    infra/auth.yaml infra/reports.yaml infra/ai.yml \
    infra/deploy-auth.sh infra/deploy-reports.sh infra/deploy-ai.sh \
    infra/destroy-auth.sh infra/destroy-reports.sh infra/destroy-ai.sh \
    infra/imports.tf infra/generated.tf
  rm -f infra/imports.tf infra/generated.tf
  echo
  echo "Done. Last step: git rm -rf infra/migrate (a script cannot delete itself on Windows),"
  echo "then check 'git status' and commit."
}

main "$@"
