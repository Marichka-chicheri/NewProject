#!/usr/bin/env bash
# Delete the Kinesis stream, Firehose, Lambda, SNS topic and the Glue table.
# The S3 objects under stream/ stay in the bucket (the bucket is not part of the stack).
set -euo pipefail
aws cloudformation delete-stack --stack-name lab8-streaming --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name lab8-streaming --region us-east-1
echo "deleted. Check nothing is left:"
aws kinesis list-streams --region us-east-1 --query StreamNames
aws firehose list-delivery-streams --region us-east-1 --query DeliveryStreamNames
