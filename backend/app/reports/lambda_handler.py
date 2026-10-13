"""AWS Lambda handler for the report-builder.

Invoked by SQS (or directly by EventBridge Scheduler / manual test).
Queries Aurora, builds the CSV report for the specified ISO week, and saves it to S3.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
import json
import logging
import os
from typing import Any

import boto3

from app.reports.weekly import build_weekly_report

# Configure logger
logger = logging.getLogger("report-builder")
logger.setLevel(logging.INFO)

if not logger.handlers:
    handler = logging.StreamHandler()
    formatter = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(message)s [trigger=%(trigger)s, week=%(week)s]"
    )
    handler.setFormatter(formatter)
    logger.addHandler(handler)


def get_previous_iso_week() -> str:
    """Return the previous ISO week string (e.g. '2026-W39')."""
    now = datetime.now(UTC)
    prev = now - timedelta(days=7)
    iso = prev.isocalendar()
    return f"{iso.year}-W{iso.week:02d}"


def parse_event(event: dict[str, Any]) -> tuple[str, str | None]:
    """Extract trigger source and target week from the event payload.

    Handles:
    - SQS event: event["Records"][0]["body"] containing JSON
    - Direct invocation / EventBridge: event payload directly
    """
    if "Records" in event and event["Records"]:
        # SQS event record
        record = event["Records"][0]
        body = record.get("body", "{}")
        try:
            payload = json.loads(body) if isinstance(body, str) else body
        except json.JSONDecodeError:
            payload = {"source": "sqs"}

        source = payload.get("source", "sqs")
        # If the SQS message came from the schedule ({"source": "schedule"}), keep "schedule"
        # If it came from CLI (make report-now) or generic SQS, label trigger as "sqs"
        trigger = "schedule" if source == "schedule" else "sqs"
        week = payload.get("week")
        return trigger, week

    # Direct invocation (Step 3 or direct lambda test)
    source = event.get("source", "direct")
    trigger = "schedule" if source == "schedule" else (source if source != "direct" else "direct")
    week = event.get("week")
    return trigger, week


def handler(event: dict[str, Any], context: Any = None) -> dict[str, Any]:
    """Lambda entrypoint for building weekly reports."""
    trigger, target_week = parse_event(event)

    if not target_week:
        target_week = get_previous_iso_week()

    # Required log line for lab submission item 5
    logger.info(
        "report-builder triggered",
        extra={"trigger": trigger, "week": target_week},
    )

    bucket = os.environ.get("REPORTS_BUCKET")
    if not bucket:
        raise RuntimeError("REPORTS_BUCKET environment variable is not set")

    # Generate CSV report
    csv_bytes = build_weekly_report(target_week)

    # Save to S3: reports/<week>.csv
    key = f"reports/{target_week}.csv"
    s3_client = boto3.client("s3")
    s3_client.put_object(
        Bucket=bucket,
        Key=key,
        Body=csv_bytes,
        ContentType="text/csv",
    )

    logger.info(
        f"Successfully generated and uploaded {key} to {bucket}",
        extra={"trigger": trigger, "week": target_week},
    )

    return {
        "statusCode": 200,
        "bucket": bucket,
        "key": key,
        "week": target_week,
        "trigger": trigger,
    }


def run_runtime_loop() -> None:
    """Standard AWS Lambda custom container runtime loop."""
    import urllib.request

    runtime_api = os.environ.get("AWS_LAMBDA_RUNTIME_API")
    if not runtime_api:
        logger.info("AWS_LAMBDA_RUNTIME_API not found; running standalone test")
        handler({"source": "cli", "week": None})
        return

    base_url = f"http://{runtime_api}/2018-06-01/runtime/invocation"
    while True:
        invocation_id = None
        try:
            req = urllib.request.Request(f"{base_url}/next")
            with urllib.request.urlopen(req) as resp:
                invocation_id = resp.headers.get("Lambda-Runtime-Aws-Request-Id")
                body = resp.read().decode("utf-8")
                event = json.loads(body) if body else {}

            res = handler(event)

            res_data = json.dumps(res).encode("utf-8")
            post_req = urllib.request.Request(
                f"{base_url}/{invocation_id}/response",
                data=res_data,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(post_req):
                pass
        except Exception as e:
            logger.exception("Error processing invocation: %s", e)
            if invocation_id:
                err_data = json.dumps({
                    "errorMessage": str(e),
                    "errorType": type(e).__name__,
                }).encode("utf-8")
                err_req = urllib.request.Request(
                    f"{base_url}/{invocation_id}/error",
                    data=err_data,
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                try:
                    with urllib.request.urlopen(err_req):
                        pass
                except Exception:
                    pass


if __name__ == "__main__":
    run_runtime_loop()

