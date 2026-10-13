"""Weekly meetings report generator.

Generates an ISO-week summary of meetings from the database as a CSV report.
Idempotent and deterministic for a given week.
"""

from __future__ import annotations

import asyncio
import csv
from datetime import UTC, datetime, timedelta
import io
import re
from typing import TYPE_CHECKING

from sqlalchemy import select
from sqlalchemy.orm import selectinload

from app.db import SessionLocal
from app.models import Meeting, Participant, User

if TYPE_CHECKING:
    from sqlalchemy.ext.asyncio import AsyncSession


def parse_iso_week(week: str) -> tuple[datetime, datetime, datetime, datetime, str]:
    """Parse an ISO week string (e.g. "2026-W40") into UTC datetime boundaries.

    Returns:
        (curr_start, curr_end, prev_start, prev_end, prev_week_str)
    """
    match = re.match(r"^(\d{4})-W(\d{1,2})$", week.strip())
    if not match:
        raise ValueError(f"Invalid ISO week format: '{week}'. Expected format 'YYYY-Www', e.g. '2026-W40'.")

    year = int(match.group(1))
    week_num = int(match.group(2))
    if not (1 <= week_num <= 53):
        raise ValueError(f"Invalid week number: {week_num}. Must be between 1 and 53.")

    # Day 1 of ISO week is Monday 00:00:00 UTC
    curr_start = datetime.fromisocalendar(year, week_num, 1).replace(
        hour=0, minute=0, second=0, microsecond=0, tzinfo=UTC
    )
    curr_end = curr_start + timedelta(days=7)

    prev_start = curr_start - timedelta(days=7)
    prev_end = curr_start

    prev_iso = prev_start.isocalendar()
    prev_week_str = f"{prev_iso.year}-W{prev_iso.week:02d}"

    return curr_start, curr_end, prev_start, prev_end, prev_week_str


async def generate_report_csv(session: AsyncSession, week: str) -> bytes:
    """Query the database and build the CSV content for the specified ISO week."""
    curr_start, curr_end, prev_start, prev_end, prev_week_str = parse_iso_week(week)

    # 1. Fetch meetings for current and previous weeks with participants
    query_curr = (
        select(Meeting)
        .options(selectinload(Meeting.participants))
        .where(Meeting.starts_at >= curr_start, Meeting.starts_at < curr_end)
        .order_by(Meeting.starts_at)
    )
    result_curr = await session.scalars(query_curr)
    curr_meetings = list(result_curr)

    query_prev = (
        select(Meeting)
        .where(Meeting.starts_at >= prev_start, Meeting.starts_at < prev_end)
    )
    result_prev = await session.scalars(query_prev)
    prev_meetings = list(result_prev)

    # Fetch users (owners) for display
    users_query = select(User)
    users_result = await session.scalars(users_query)
    users_by_id = {u.id: u for u in users_result}

    # 2. Compute summary metrics
    curr_count = len(curr_meetings)
    curr_duration_hours = sum(
        (m.ends_at - m.starts_at).total_seconds() / 3600.0 for m in curr_meetings
    )

    prev_count = len(prev_meetings)
    prev_duration_hours = sum(
        (m.ends_at - m.starts_at).total_seconds() / 3600.0 for m in prev_meetings
    )

    diff_count = curr_count - prev_count
    diff_duration = curr_duration_hours - prev_duration_hours

    def format_diff(diff: float, prev: float, is_int: bool = False) -> str:
        sign = "+" if diff > 0 else ""
        diff_str = f"{sign}{int(diff)}" if is_int else f"{sign}{diff:.2f}"
        if prev > 0:
            pct = (diff / prev) * 100.0
            return f"{diff_str} ({sign}{pct:.1f}%)"
        return diff_str

    # 3. Top 5 longest meetings
    longest_meetings = sorted(
        curr_meetings,
        key=lambda m: (m.ends_at - m.starts_at).total_seconds(),
        reverse=True,
    )[:5]

    # 4. Breakdown by organizer (owner)
    organizer_stats: dict[str, dict[str, float | int | str]] = {}
    for m in curr_meetings:
        owner = users_by_id.get(m.owner_id)
        owner_name = owner.name if owner else f"User {m.owner_id}"
        owner_email = owner.email if owner else "unknown"
        key = str(m.owner_id)
        if key not in organizer_stats:
            organizer_stats[key] = {
                "name": owner_name,
                "email": owner_email,
                "count": 0,
                "hours": 0.0,
            }
        duration = (m.ends_at - m.starts_at).total_seconds() / 3600.0
        organizer_stats[key]["count"] = int(organizer_stats[key]["count"]) + 1
        organizer_stats[key]["hours"] = float(organizer_stats[key]["hours"]) + duration

    # 5. Breakdown by participant
    participant_stats: dict[str, dict[str, float | int | str]] = {}
    for m in curr_meetings:
        duration = (m.ends_at - m.starts_at).total_seconds() / 3600.0
        for p in m.participants:
            pkey = str(p.id)
            if pkey not in participant_stats:
                participant_stats[pkey] = {
                    "name": p.name,
                    "email": p.email,
                    "count": 0,
                    "hours": 0.0,
                }
            participant_stats[pkey]["count"] = int(participant_stats[pkey]["count"]) + 1
            participant_stats[pkey]["hours"] = float(participant_stats[pkey]["hours"]) + duration

    # 6. Build CSV text
    output = io.StringIO()
    writer = csv.writer(output)

    # Header section
    writer.writerow(["=== WEEKLY MEETINGS REPORT ==="])
    writer.writerow(["Week", week])
    writer.writerow([
        "Period (UTC)",
        f"{curr_start.strftime('%Y-%m-%d')} to {(curr_end - timedelta(seconds=1)).strftime('%Y-%m-%d')}",
    ])
    writer.writerow([])

    # Metrics section
    writer.writerow(["Metric", f"This Week ({week})", f"Previous Week ({prev_week_str})", "Change"])
    writer.writerow([
        "Number of meetings",
        str(curr_count),
        str(prev_count),
        format_diff(diff_count, prev_count, is_int=True),
    ])
    writer.writerow([
        "Total duration (hours)",
        f"{curr_duration_hours:.2f}",
        f"{prev_duration_hours:.2f}",
        format_diff(diff_duration, prev_duration_hours, is_int=False),
    ])
    writer.writerow([])

    # Top 5 longest meetings
    writer.writerow(["=== 5 LONGEST MEETINGS ==="])
    writer.writerow(["Title", "Start (UTC)", "Duration (hours)", "Participants Count", "Place", "Organizer"])
    if longest_meetings:
        for m in longest_meetings:
            dur = (m.ends_at - m.starts_at).total_seconds() / 3600.0
            owner = users_by_id.get(m.owner_id)
            owner_label = f"{owner.name} ({owner.email})" if owner else str(m.owner_id)
            writer.writerow([
                m.title,
                m.starts_at.strftime("%Y-%m-%d %H:%M"),
                f"{dur:.2f}",
                len(m.participants),
                m.place,
                owner_label,
            ])
    else:
        writer.writerow(["No meetings recorded for this week"])
    writer.writerow([])

    # Organizer breakdown
    writer.writerow(["=== BREAKDOWN BY ORGANIZER ==="])
    writer.writerow(["Organizer Name", "Email", "Meetings Hosted", "Total Hours"])
    if organizer_stats:
        for stat in sorted(organizer_stats.values(), key=lambda s: float(s["hours"]), reverse=True):
            writer.writerow([
                stat["name"],
                stat["email"],
                stat["count"],
                f"{float(stat['hours']):.2f}",
            ])
    else:
        writer.writerow(["No organizer data"])
    writer.writerow([])

    # Participant breakdown
    writer.writerow(["=== BREAKDOWN BY PARTICIPANT ==="])
    writer.writerow(["Participant Name", "Email", "Meetings Attended", "Total Hours"])
    if participant_stats:
        for pstat in sorted(participant_stats.values(), key=lambda s: float(s["hours"]), reverse=True):
            writer.writerow([
                pstat["name"],
                pstat["email"],
                pstat["count"],
                f"{float(pstat['hours']):.2f}",
            ])
    else:
        writer.writerow(["No participant data"])

    return output.getvalue().encode("utf-8")


def build_weekly_report(week: str) -> bytes:
    """Query the meetings of one ISO week (e.g. '2026-W40') and return the CSV."""
    async def _runner() -> bytes:
        async with SessionLocal() as session:
            return await generate_report_csv(session, week)

    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = None

    if loop and loop.is_running():
        import concurrent.futures
        with concurrent.futures.ThreadPoolExecutor() as executor:
            return executor.submit(asyncio.run, _runner()).result()
    else:
        return asyncio.run(_runner())
