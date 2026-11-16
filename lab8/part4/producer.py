"""Replay one day of payment events into the Kinesis stream lab8-payments.

    uv run part4/producer.py --start 2026-10-01T08:00:00Z --limit 12000
    uv run part4/producer.py --start 2026-10-01T12:00:00Z --limit 6000 --fail-rate 0.3

Same replay as Part 3 (receivedAt order, ~20 payments/s, invoiceId as the key).
PutRecords takes up to 500 records per call, so events are buffered for at most
half a second. Each record ends with a newline: Firehose concatenates records
into one S3 object, and Athena reads that object as JSON Lines.
`sentAt` records when the event entered the stream, to measure end-to-end delay.
"""

import argparse
import json
import pathlib
import sys
import time
from datetime import datetime, timezone

import boto3

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from common import force_failures, load_day, replay  # noqa: E402


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--file", default="data/2026-10-01.jsonl")
    p.add_argument("--stream", default="lab8-payments")
    p.add_argument("--region", default="us-east-1")
    p.add_argument("--rate", type=float, default=20, help="payments per second")
    p.add_argument("--start")
    p.add_argument("--limit", type=int)
    p.add_argument("--fail-rate", type=float, default=0.0)
    a = p.parse_args()

    kinesis = boto3.client("kinesis", region_name=a.region)
    events = load_day(a.file, a.start)
    if a.fail_rate:
        print(f"forced {force_failures(events, a.fail_rate)} payments to fail")

    buffer: list[dict] = []
    last_flush = time.monotonic()
    stats = {"sent": 0, "retried": 0, "calls": 0}

    def flush() -> None:
        nonlocal buffer, last_flush
        records = buffer
        while records:
            resp = kinesis.put_records(StreamName=a.stream, Records=records)
            stats["calls"] += 1
            if resp["FailedRecordCount"] == 0:
                break
            # Throttled records come back with an ErrorCode; resend only those.
            records = [r for r, res in zip(records, resp["Records"]) if "ErrorCode" in res]
            stats["retried"] += len(records)
            time.sleep(0.2)
        stats["sent"] += len(buffer)
        buffer = []
        last_flush = time.monotonic()

    def send(e: dict) -> None:
        e = dict(e, sentAt=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        data = (json.dumps(e, ensure_ascii=False) + "\n").encode()
        buffer.append({"Data": data, "PartitionKey": e["invoiceId"]})
        if len(buffer) >= 500 or time.monotonic() - last_flush > 0.5:
            flush()

    t0 = time.monotonic()
    replay(events, a.rate, a.limit, send)
    if buffer:
        flush()
    print(f"done: {stats['sent']} events in {time.monotonic() - t0:.0f} s, "
          f"{stats['calls']} PutRecords calls, {stats['retried']} records retried")


if __name__ == "__main__":
    main()
