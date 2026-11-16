"""Shared by the Redpanda and Kinesis producers: load one day and replay it."""

import json
import pathlib
import random
import time
from collections.abc import Callable

FAILURE_REASONS = ["Недостатньо коштів", "Невірний CVV", "Відхилено банком"]


def load_day(path: str | pathlib.Path, start: str | None = None) -> list[dict]:
    """One day of events, ordered by processing time (receivedAt), as they reached us.

    `start` (e.g. "2026-10-01T08:00:00Z") skips the quiet night hours, so the
    windows in a short experiment have enough payments in them.
    """
    with open(path, encoding="utf-8") as f:
        events = [json.loads(line) for line in f if line.strip()]
    if start:
        events = [e for e in events if e["receivedAt"] >= start]
    # Stable sort: duplicates and events with the same second keep their file order.
    events.sort(key=lambda e: e["receivedAt"])
    return events


def force_failures(events: list[dict], share: float, seed: int = 42) -> int:
    """Turn `share` of the successful payments into failures (experiment 3).

    Only the final event changes: status success -> failure, finalAmount -> 0,
    a failureReason appears. Returns how many payments were changed.
    """
    rnd = random.Random(seed)
    succeeded = sorted({e["invoiceId"] for e in events if e["status"] == "success"})
    victims = {i for i in succeeded if rnd.random() < share}
    reason = {i: rnd.choice(FAILURE_REASONS) for i in victims}
    for e in events:
        if e["invoiceId"] in victims and e["status"] == "success":
            e["status"] = "failure"
            e["finalAmount"] = 0
            e["failureReason"] = reason[e["invoiceId"]]
    return len(victims)


def replay(events: list[dict], payments_per_sec: float, limit: int | None,
           on_event: Callable[[dict], None], log_every: int = 2000) -> int:
    """Send events in receivedAt order at about `payments_per_sec` payments a second.

    One payment is ~3 events, so the event rate is ~3x the payment rate.
    Pacing is by wall clock against a schedule, so a slow send does not
    accumulate drift.
    """
    total_events = len(events) if limit is None else min(limit, len(events))
    events_per_payment = len(events) / max(1, len({e["invoiceId"] for e in events}))
    interval = 1.0 / (payments_per_sec * events_per_payment)
    start = time.monotonic()
    for n, e in enumerate(events[:total_events], 1):
        target = start + n * interval
        delay = target - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        on_event(e)
        if n % log_every == 0:
            rate = n / (time.monotonic() - start)
            print(f"sent {n}/{total_events} events ({rate:.0f} ev/s), receivedAt={e['receivedAt']}", flush=True)
    return total_events
