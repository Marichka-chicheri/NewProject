from datetime import UTC, datetime, timedelta
import pytest
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.models import Meeting, Participant, User
from app.reports.weekly import generate_report_csv, parse_iso_week


def test_parse_iso_week():
    curr_start, curr_end, prev_start, prev_end, prev_week_str = parse_iso_week("2026-W40")
    assert curr_start == datetime(2026, 9, 28, 0, 0, tzinfo=UTC)
    assert curr_end == datetime(2026, 10, 5, 0, 0, tzinfo=UTC)
    assert prev_start == datetime(2026, 9, 21, 0, 0, tzinfo=UTC)
    assert prev_end == datetime(2026, 9, 28, 0, 0, tzinfo=UTC)
    assert prev_week_str == "2026-W39"


def test_parse_iso_week_invalid():
    with pytest.raises(ValueError):
        parse_iso_week("invalid")
    with pytest.raises(ValueError):
        parse_iso_week("2026-W60")


@pytest.mark.asyncio
async def test_generate_report_csv(engine):
    sessionmaker = async_sessionmaker(engine, expire_on_commit=False)
    async with sessionmaker() as session:
        # Create user and participant
        user = User(cognito_sub="sub123", email="user@example.com", name="Test User")
        session.add(user)
        part = Participant(name="Bob Smith", email="bob@example.com")
        session.add(part)
        await session.flush()

        # Target week: 2026-W40 (2026-09-28 to 2026-10-04)
        m1 = Meeting(
            title="Sprint Planning",
            description="Discuss sprint goals",
            starts_at=datetime(2026, 9, 29, 10, 0, tzinfo=UTC),
            ends_at=datetime(2026, 9, 29, 11, 30, tzinfo=UTC),
            place="Room 101",
            owner_id=user.id,
            participants=[part],
        )
        # Previous week: 2026-W39 (2026-09-21 to 2026-09-27)
        m2 = Meeting(
            title="Backlog Refinement",
            description="Estimate stories",
            starts_at=datetime(2026, 9, 22, 14, 0, tzinfo=UTC),
            ends_at=datetime(2026, 9, 22, 15, 0, tzinfo=UTC),
            place="Online",
            owner_id=user.id,
            participants=[],
        )
        session.add_all([m1, m2])
        await session.commit()

        csv_bytes = await generate_report_csv(session, "2026-W40")
        csv_text = csv_bytes.decode("utf-8")

        assert "=== WEEKLY MEETINGS REPORT ===" in csv_text
        assert "2026-W40" in csv_text
        assert "Sprint Planning" in csv_text
        assert "Test User" in csv_text
        assert "Bob Smith" in csv_text
