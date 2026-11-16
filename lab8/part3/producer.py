"""Replay one day of payment events into the Redpanda topic `payments`.

    aws s3 cp s3://lab8-payments-274394226432/payments/dt=2026-10-01/events.jsonl data/2026-10-01.jsonl
    uv run part3/producer.py --start 2026-10-01T08:00:00Z --limit 30000
    uv run part3/producer.py --start 2026-10-01T08:00:00Z --limit 30000 --fail-rate 0.3

Events go out in receivedAt order (processing time), so an event that was late in
the dataset is late here too. The key is invoiceId: Kafka hashes the key to pick a
partition, so all events of one payment land in one partition, in order.
"""

import argparse
import json
import pathlib
import sys

from confluent_kafka import Producer

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from common import force_failures, load_day, replay  # noqa: E402


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--file", default="data/2026-10-01.jsonl")
    p.add_argument("--brokers", default="localhost:19092")
    p.add_argument("--topic", default="payments")
    p.add_argument("--rate", type=float, default=20, help="payments per second")
    p.add_argument("--start", help="skip events received before this time, e.g. 2026-10-01T08:00:00Z")
    p.add_argument("--limit", type=int, help="send at most this many events")
    p.add_argument("--fail-rate", type=float, default=0.0, help="turn this share of successes into failures")
    a = p.parse_args()

    events = load_day(a.file, a.start)
    if a.fail_rate:
        n = force_failures(events, a.fail_rate)
        print(f"forced {n} payments to fail ({a.fail_rate:.0%} of successes)")
    print(f"replaying {len(events)} events at ~{a.rate} payments/s into {a.topic}")

    producer = Producer({
        "bootstrap.servers": a.brokers,
        "acks": "all",              # wait until the broker has written the event
        "enable.idempotence": True, # retries do not create duplicates in the log
        "linger.ms": 20,            # small batches: fewer requests, still near real time
    })
    errors = 0

    def delivered(err, _msg):
        nonlocal errors
        if err:
            errors += 1
            print("delivery failed:", err, file=sys.stderr)

    def send(e: dict) -> None:
        producer.produce(a.topic, key=e["invoiceId"],
                         value=json.dumps(e, ensure_ascii=False).encode(),
                         on_delivery=delivered)
        producer.poll(0)  # serve delivery callbacks without blocking

    try:
        sent = replay(events, a.rate, a.limit, send)
    except KeyboardInterrupt:
        sent = None
    producer.flush(30)
    print(f"done: sent {sent if sent is not None else 'interrupted'}, delivery errors {errors}")


if __name__ == "__main__":
    main()
