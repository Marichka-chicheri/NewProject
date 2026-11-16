#!/usr/bin/env bash
# Way B: let a Glue Crawler infer the schema of payments/ and compare it with ours.
# Creates an IAM role for Glue, a separate database lab8_crawler (so the crawled
# table does not clash with the hand-written one), runs the crawler, prints the schema.
set -euo pipefail
BUCKET=${LAB8_BUCKET:-lab8-payments-274394226432}
ROLE=lab8-glue-crawler
DB=lab8_crawler
CRAWLER=lab8-payments-crawler

if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"glue.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole
  aws iam put-role-policy --role-name "$ROLE" --policy-name read-payments --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],
      \"Resource\":[\"arn:aws:s3:::$BUCKET\",\"arn:aws:s3:::$BUCKET/payments/*\"]}]}"
  sleep 10  # IAM is eventually consistent
fi

aws glue create-database --database-input "Name=$DB" 2>/dev/null || true
aws glue create-crawler --name "$CRAWLER" --role "$ROLE" --database-name "$DB" \
  --targets "S3Targets=[{Path=s3://$BUCKET/payments/}]" 2>/dev/null || true
aws glue start-crawler --name "$CRAWLER"

echo "waiting for the crawler..."
sleep 20
while [ "$(aws glue get-crawler --name "$CRAWLER" --query Crawler.State --output text)" != "READY" ]; do
  sleep 10
done
aws glue get-crawler --name "$CRAWLER" --query Crawler.LastCrawl

TABLE=$(aws glue get-tables --database-name "$DB" --query 'TableList[0].Name' --output text)
echo "table: $DB.$TABLE"
aws glue get-table --database-name "$DB" --name "$TABLE" \
  --query 'Table.{columns:StorageDescriptor.Columns,partitions:PartitionKeys,serde:StorageDescriptor.SerdeInfo.SerializationLibrary,classification:Parameters.classification}'
