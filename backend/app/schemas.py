import uuid
from datetime import UTC, date, datetime
from typing import Annotated, Any

from pydantic import (
    AfterValidator,
    BaseModel,
    ConfigDict,
    EmailStr,
    Field,
    StringConstraints,
    field_serializer,
    model_validator,
)

NonEmptyStr = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1)]


def _require_tz(value: datetime) -> datetime:
    if value.tzinfo is None:
        raise ValueError("datetime must include a time-zone offset")
    return value.astimezone(UTC)


AwareDatetime = Annotated[datetime, AfterValidator(_require_tz)]


class UserRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    email: str
    name: str


class ParticipantCreate(BaseModel):
    name: Annotated[NonEmptyStr, StringConstraints(max_length=100)]
    email: Annotated[EmailStr, StringConstraints(max_length=255)]


class ParticipantRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    email: str


class MeetingCreate(BaseModel):
    title: Annotated[NonEmptyStr, StringConstraints(max_length=200)]
    description: str = ""
    starts_at: AwareDatetime
    ends_at: AwareDatetime
    place: Annotated[NonEmptyStr, StringConstraints(max_length=200)]
    participant_ids: list[uuid.UUID] = []

    @model_validator(mode="after")
    def check_times(self) -> MeetingCreate:
        if self.ends_at <= self.starts_at:
            raise ValueError("ends_at must be after starts_at")
        # de-duplicate while keeping order
        self.participant_ids = list(dict.fromkeys(self.participant_ids))
        return self


def _blank_to_none(value: str | None) -> str | None:
    return value or None


# A name or an email, exactly as the user wrote it; an empty string means "no owner".
OptionalOwner = Annotated[
    Annotated[str, StringConstraints(strip_whitespace=True, max_length=255)] | None,
    AfterValidator(_blank_to_none),
]


class AgendaItem(BaseModel):
    topic: Annotated[NonEmptyStr, StringConstraints(max_length=300)]
    owner: OptionalOwner = None
    minutes: int | None = Field(default=None, ge=1, le=480)


class ActionItem(BaseModel):
    task: Annotated[NonEmptyStr, StringConstraints(max_length=500)]
    owner: OptionalOwner = None
    due: date | None = None


class Agenda(BaseModel):
    items: list[AgendaItem] = Field(default=[], max_length=50)
    action_items: list[ActionItem] = Field(default=[], max_length=50)

    @model_validator(mode="after")
    def not_empty(self) -> Agenda:
        if not self.items and not self.action_items:
            raise ValueError("an agenda needs at least one item or action item")
        return self


class AiSuggestion(BaseModel):
    """What the agenda parser returned, sent back by the browser when the user saves."""

    agenda: dict[str, Any]
    # The pasted text, so a new prompt version can be re-run on the same inputs later.
    text: Annotated[str, StringConstraints(max_length=10_000)] = ""
    model: Annotated[NonEmptyStr, StringConstraints(max_length=100)]
    prompt_version: Annotated[NonEmptyStr, StringConstraints(max_length=50)]


class AgendaSave(Agenda):
    # Present only when the form was pre-filled by the parser.
    ai_suggestion: AiSuggestion | None = None


class MeetingRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    title: str
    description: str
    starts_at: datetime
    ends_at: datetime
    place: str
    participants: list[ParticipantRead]
    agenda: Agenda | None = None
    created_at: datetime

    @field_serializer("starts_at", "ends_at", "created_at")
    def to_utc(self, value: datetime) -> str:
        return value.astimezone(UTC).isoformat().replace("+00:00", "Z")
