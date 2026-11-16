#!/usr/bin/env bash
# Create (or update) the Part 4 stack. Optional: ALERT_EMAIL=you@example.com
set -euo pipefail
cd "$(dirname "$0")"
aws cloudformation deploy \
  --stack-name lab8-streaming \
  --template-file stack.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides "AlertEmail=${ALERT_EMAIL:-}" \
  --region us-east-1
aws cloudformation describe-stacks --stack-name lab8-streaming --region us-east-1 \
  --query 'Stacks[0].Outputs' --output table
