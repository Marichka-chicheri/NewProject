"""Failure share per paymentMethod in one-minute event-time windows, with alerts.

    uv run part3/consumer.py                      # lateness 120 s (default)
    uv run part3/consumer.py --lateness 0         # experiment 4
    uv run part3/consumer.py --group g2 --name A  # experiment 2: run twice with one group

Event time is modifiedDate (when the status happened), not the time we read it.
A window [t, t+60s) is closed once the watermark (the latest event time seen)
passes t + 60s + lateness. An outcome event for a window that is already closed
is counted as rejected-late and does not change the published numbers.
"""

import argparse
import json
import signal
import time
from collections import defaultdict
from datetime import datetime, timedelta, timezone

from confluent_kafka import Consumer, KafkaError

WINDOW = timedelta(minutes=1)


def ts(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def floor_minute(t: datetime) -> datetime:
    return t.replace(second=0, microsecond=0)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--brokers", default="localhost:19092")
    p.add_argument("--topic", default="payments")
    p.add_argument("--group", default="failure-monitor")
    p.add_argument("--name", default="", help="label in the output (two consumers)")
    p.add_argument("--lateness", type=int, default=120, help="seconds to wait for late events")
    p.add_argument("--threshold", type=float, default=0.10, help="alert above this failure share")
    p.add_argument("--min-count", type=int, default=10, help="no alert on fewer finished payments")
    p.add_argument("--idle-exit", type=float, default=0, help="stop after this many idle seconds (0 = never)")
    p.add_argument("--quiet", action="store_true", help="print alerts only, not every window")
    a = p.parse_args()
    tag = f"[{a.name}] " if a.name else ""
    lateness = timedelta(seconds=a.lateness)

    consumer = Consumer({
        "bootstrap.servers": a.brokers,
        "group.id": a.group,
        "auto.offset.reset": "earliest",  # a new group starts from the start of the log
        "enable.auto.commit": True,       # offsets are committed every 5 s
    })

    def on_assign(_c, parts):
        print(f"{tag}assigned partitions {[x.partition for x in parts]}", flush=True)

    def on_revoke(_c, parts):
        print(f"{tag}revoked partitions {[x.partition for x in parts]}", flush=True)

    consumer.subscribe([a.topic], on_assign=on_assign, on_revoke=on_revoke)

    seen: set[tuple[str, str]] = set()  # (invoiceId, status): grows without limit, see the report
    # window start -> paymentMethod -> [finished, failed]
    windows: dict[datetime, dict[str, list[int]]] = defaultdict(lambda: defaultdict(lambda: [0, 0]))
    watermark: datetime | None = None
    stats = defaultdict(int)
    late_by_window: dict[datetime, int] = defaultdict(int)

    def close_ready() -> None:
        for start in sorted(w for w in windows if w + WINDOW + lateness <= watermark):
            per_method = windows.pop(start)
            stats["windows"] += 1
            parts = []
            for method, (fin, fail) in sorted(per_method.items()):
                share = fail / fin if fin else 0.0
                parts.append(f"{method} {fail}/{fin}={share:.0%}")
                if fin >= a.min_count and share > a.threshold:
                    stats["alerts"] += 1
                    print(f"{tag}ALERT {start:%H:%M} {method}: failure {share:.1%} ({fail}/{fin}) > {a.threshold:.0%}",
                          flush=True)
            if not a.quiet:
                print(f"{tag}window {start:%H:%M}  " + "  ".join(parts), flush=True)

    stop = False

    def handle_sigint(*_):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, handle_sigint)
    last_msg = time.monotonic()

    while not stop:
        msg = consumer.poll(1.0)
        if msg is None:
            if a.idle_exit and time.monotonic() - last_msg > a.idle_exit:
                break
            continue
        if msg.error():
            if msg.error().code() != KafkaError._PARTITION_EOF:
                print(f"{tag}error: {msg.error()}")
            continue
        last_msg = time.monotonic()
        stats["read"] += 1
        e = json.loads(msg.value())

        # 1. Deduplicate: the same status of the same payment counts once.
        key = (e["invoiceId"], e["status"])
        if key in seen:
            stats["duplicates"] += 1
            continue
        seen.add(key)

        # 2. Event time and watermark. Every status moves the watermark,
        #    only outcomes (success/failure) are counted in windows.
        t = ts(e["modifiedDate"])
        watermark = t if watermark is None or t > watermark else watermark
        if e["status"] in ("success", "failure"):
            start = floor_minute(t)
            if start + WINDOW + lateness <= watermark:
                stats["late_rejected"] += 1      # its window is already published
                late_by_window[start] += 1
            else:
                cell = windows[start][e["paymentMethod"]]
                cell[0] += 1
                cell[1] += e["status"] == "failure"
        close_ready()

        if stats["read"] % 5000 == 0:
            print(f"{tag}progress: read {stats['read']}, watermark {watermark:%H:%M:%S}, "
                  f"dups {stats['duplicates']}, late rejected {stats['late_rejected']}", flush=True)

    consumer.close()  # commits the final offsets and leaves the group cleanly
    print(f"{tag}summary: read {stats['read']}, duplicates dropped {stats['duplicates']}, "
          f"late rejected {stats['late_rejected']}, windows closed {stats['windows']}, "
          f"open windows {len(windows)}, alerts {stats['alerts']}, seen-set size {len(seen)}", flush=True)
    if late_by_window:
        worst = sorted(late_by_window.items(), key=lambda kv: -kv[1])[:5]
        print(f"{tag}most late events in windows: " + ", ".join(f"{w:%H:%M}={n}" for w, n in worst))


if __name__ == "__main__":
    main()
