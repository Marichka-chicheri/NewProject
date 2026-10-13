"""AWS Lambda handler for the report-mailer.

Runs outside the VPC with standard internet egress.
Triggered by S3 ObjectCreated events when a report CSV is uploaded.
Downloads the report and sends it as an attachment via Amazon SES.
"""

from __future__ import annotations

from email.message import EmailMessage
import json
import logging
import os
from typing import Any
import urllib.parse

import boto3

logger = logging.getLogger("report-mailer")
logger.setLevel(logging.INFO)

if not logger.handlers:
    handler_stdout = logging.StreamHandler()
    formatter = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(message)s [trigger=%(trigger)s, key=%(key)s]"
    )
    handler_stdout.setFormatter(formatter)
    logger.addHandler(handler_stdout)

s3_client = boto3.client("s3")
ses_client = boto3.client("sesv2")


def handler(event: dict[str, Any], context: Any = None) -> dict[str, Any]:
    """Lambda entrypoint triggered by S3 ObjectCreated."""
    if not event.get("Records"):
        logger.warning("No records found in S3 event")
        return {"status": "ignored", "reason": "no records"}

    record = event["Records"][0]
    bucket = record["s3"]["bucket"]["name"]
    key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

    # Required log line for lab submission item 5
    logger.info("report-mailer triggered", extra={"trigger": "s3", "key": key})
    print(f"report-mailer triggered: trigger=s3, key={key}")

    # Guard: never write back to reports/ prefix to avoid infinite loops!
    # Download report CSV from S3
    response = s3_client.get_object(Bucket=bucket, Key=key)
    csv_bytes = response["Body"].read()

    filename = os.path.basename(key)
    sender = os.environ.get("SENDER_EMAIL")
    recipient_env = os.environ.get("RECIPIENT_EMAIL")

    if not sender or not recipient_env:
        raise RuntimeError("SENDER_EMAIL and RECIPIENT_EMAIL environment variables must be set")

    recipients = [r.strip() for r in recipient_env.split(",") if r.strip()]

    # Build MIME message with attachment
    week_name = filename.replace(".csv", "")
    msg = EmailMessage()
    msg["Subject"] = f"Weekly Meetings Report: {week_name}"
    msg["From"] = sender
    msg["To"] = ", ".join(recipients)
    msg.set_content(
        f"Hi,\n\nPlease find attached the meetings summary report for {week_name}.\n\n"
        "Best regards,\nMeetings App"
    )

    msg.add_attachment(
        csv_bytes,
        maintype="text",
        subtype="csv",
        filename=filename,
    )

    # Send via Amazon SES
    ses_client.send_email(
        FromEmailAddress=sender,
        Destination={"ToAddresses": recipients},
        Content={"Raw": {"Data": msg.as_bytes()}},
    )

    logger.info(f"Delivered {filename} to {recipients}", extra={"trigger": "s3", "key": key})

    return {
        "status": "delivered",
        "key": key,
        "recipients": recipients,
    }
