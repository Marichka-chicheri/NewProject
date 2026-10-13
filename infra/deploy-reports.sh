#!/usr/bin/env bash
# Deploys the reports infrastructure (EventBridge Scheduler, SQS, DLQ, Lambdas, S3)
# via `make deploy-reports`.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  stack_exists "$BACKEND_STACK" || {
    echo "Stack $BACKEND_STACK not found. Please deploy the backend first (make deploy-backend)." >&2
    exit 1
  }

  echo "==> Deploying '$PROJECT_NAME' reports infrastructure to $AWS_REGION"

  # 1. Resolve VPC, subnets, security group, and endpoint from backend stack
  VpcId="$(output "$BACKEND_STACK" VpcId)"
  SubnetA="$(output "$BACKEND_STACK" PrivateSubnetA)"
  SubnetB="$(output "$BACKEND_STACK" PrivateSubnetB)"
  SecGroup="$(output "$BACKEND_STACK" FunctionSecurityGroup)"
  Endpoint="$(output "$BACKEND_STACK" DatabaseEndpoint)"

  # Fallback: if backend was deployed prior to adding Outputs, query Lambda VPC config
  if [ -z "$VpcId" ] || [ "$VpcId" = "None" ]; then
    echo "    Querying Lambda function configuration for VPC details..."
    fn_conf="$(aws lambda get-function-configuration --function-name "$PROJECT_NAME-backend")"
    VpcId="$(echo "$fn_conf" | python3 -c 'import json, sys; print(json.load(sys.stdin)["VpcConfig"]["VpcId"])')"
    SubnetA="$(echo "$fn_conf" | python3 -c 'import json, sys; print(json.load(sys.stdin)["VpcConfig"]["SubnetIds"][0])')"
    SubnetB="$(echo "$fn_conf" | python3 -c 'import json, sys; print(json.load(sys.stdin)["VpcConfig"]["SubnetIds"][1])')"
    SecGroup="$(echo "$fn_conf" | python3 -c 'import json, sys; print(json.load(sys.stdin)["VpcConfig"]["SecurityGroupIds"][0])')"
  fi

  # Route table for the VPC (needed for S3 Gateway Endpoint)
  RouteTableId="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VpcId" --query "RouteTables[0].RouteTableId" --output text)"

  # Database URL
  PASSWORD_PARAM="/$PROJECT_NAME/db-password"
  db_password="$(aws ssm get-parameter --name "$PASSWORD_PARAM" --with-decryption --query Parameter.Value --output text)"
  DatabaseUrl="postgresql+asyncpg://meetings:${db_password}@${Endpoint}:5432/meetings"

  # ECR container image URI (reuse the image currently deployed on the backend function)
  ImageUri="$(aws lambda get-function --function-name "$PROJECT_NAME-backend" --query "Code.ImageUri" --output text)"

  # Email parameters
  SenderEmail="${REPORTS_SENDER_EMAIL:-reports@${DOMAIN_NAME:-example.com}}"
  RecipientEmail="${REPORTS_RECIPIENT_EMAIL:-${SenderEmail}}"

  echo "    VPC: $VpcId"
  echo "    Subnets: $SubnetA, $SubnetB"
  echo "    Security Group: $SecGroup"
  echo "    Route Table: $RouteTableId"
  echo "    Image URI: $ImageUri"
  echo "    Sender: $SenderEmail"
  echo "    Recipient: $RecipientEmail"

  aws cloudformation deploy \
    --stack-name "$REPORTS_STACK" \
    --template-file infra/reports.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
      "ProjectName=$PROJECT_NAME" \
      "ImageUri=$ImageUri" \
      "VpcId=$VpcId" \
      "SubnetIds=$SubnetA,$SubnetB" \
      "SecurityGroupId=$SecGroup" \
      "RouteTableIds=$RouteTableId" \
      "DatabaseUrl=$DatabaseUrl" \
      "SenderEmail=$SenderEmail" \
      "RecipientEmail=$RecipientEmail" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset

  bucket="$(output "$REPORTS_STACK" ReportsBucketName)"
  queue_url="$(output "$REPORTS_STACK" ReportRequestsQueueUrl)"
  dlq_url="$(output "$REPORTS_STACK" ReportRequestsDLQUrl)"

  echo
  echo "==> Reports infrastructure deployed successfully!"
  echo "    Bucket: s3://$bucket"
  echo "    SQS Queue: $queue_url"
  echo "    DLQ: $dlq_url"
}

main "$@"
