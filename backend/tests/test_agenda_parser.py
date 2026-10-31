"""The parser and its Lambda handler, with a fake model: no test calls Bedrock."""

import json
import logging
from datetime import date
from types import SimpleNamespace

import anthropic
import httpx
import pytest

from app.ai import agenda as agenda_module
from app.ai import agenda_lambda
from app.ai.agenda import PROMPT_VERSION, AgendaParseError, cost_usd, parse_agenda
from app.auth import TokenVerifier
from tests.conftest import CLIENT_ID, JWKS, POOL_ID, make_token

CLAUDE = "anthropic.test"

GOOD = {
    "title": "Синк по прайсингу",
    "starts_at": "2026-11-02T10:00:00+02:00",
    "duration_minutes": 45,
    "items": [{"topic": "нові тарифи Pro", "owner": "Олена", "minutes": 15}],
    "action_items": [{"task": "порівняння з конкурентами", "owner": "Taras", "due": "2026-10-30"}],
    "language": "uk",
}


def tool_message(tool_input: dict, tokens: tuple[int, int] = (1000, 200)) -> SimpleNamespace:
    block = SimpleNamespace(type="tool_use", id="toolu_1", name="record_agenda", input=tool_input)
    return SimpleNamespace(
        content=[block],
        stop_reason="tool_use",
        usage=SimpleNamespace(input_tokens=tokens[0], output_tokens=tokens[1]),
    )


class FakeClient:
    """Answers with the given messages in order and records every request."""

    def __init__(self, *answers) -> None:
        self.answers = list(answers)
        self.requests: list[dict] = []
        self.messages = self

    def create(self, **request):
        self.requests.append(json.loads(json.dumps(request, default=vars)))
        answer = self.answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer


def test_parse_puts_today_and_delimited_text_in_the_prompt() -> None:
    client = FakeClient(tool_message(GOOD))
    agenda, usage = parse_agenda(
        "Пн 10:00, синк", date(2026, 10, 28), "Europe/Kyiv", model=CLAUDE, client=client
    )
    assert agenda.items[0].owner == "Олена"
    assert usage == {"input_tokens": 1000, "output_tokens": 200}
    prompt = client.requests[0]["messages"][0]["content"]
    assert "Today is Wednesday 2026-10-28, time zone Europe/Kyiv" in prompt
    assert "<pasted_text>\nПн 10:00, синк\n</pasted_text>" in prompt
    assert client.requests[0]["tools"][0]["name"] == "record_agenda"
    assert "tool_choice" not in client.requests[0]


def test_v2_prompt_gives_a_calendar_and_the_utc_offset() -> None:
    client = FakeClient(tool_message(GOOD))
    parse_agenda("Пн 10:00", date(2026, 10, 31), "Europe/Kyiv", model=CLAUDE, client=client)
    prompt = client.requests[0]["messages"][0]["content"]
    assert "UTC offset +02:00" in prompt
    assert "Mon 2026-11-02" in prompt and "Fri 2026-11-06" in prompt


def test_v2_schema_rejects_language_names_and_blanks_owners() -> None:
    from app.ai.agenda import ParsedAgenda

    agenda = ParsedAgenda.model_validate({**GOOD, "items": [{"topic": "Retro", "owner": ""}]})
    assert agenda.items[0].owner is None
    with pytest.raises(ValueError):
        ParsedAgenda.model_validate({**GOOD, "language": "English"})


def test_invalid_answer_is_shown_to_the_model_once() -> None:
    client = FakeClient(tool_message({**GOOD, "items": [{"topic": ""}]}), tool_message(GOOD))
    agenda, usage = parse_agenda("x", date(2026, 10, 28), "UTC", model=CLAUDE, client=client)
    assert agenda.title == "Синк по прайсингу"
    assert usage == {"input_tokens": 2000, "output_tokens": 400}
    retry = client.requests[1]["messages"][-1]["content"][0]
    assert retry["type"] == "tool_result" and retry["is_error"] is True


def test_invalid_twice_raises_with_usage() -> None:
    bad = tool_message({"items": "not a list", "language": "uk"})
    client = FakeClient(bad, bad)
    with pytest.raises(AgendaParseError) as error:
        parse_agenda("x", date(2026, 10, 28), "UTC", model=CLAUDE, client=client)
    assert error.value.usage["input_tokens"] == 2000


def test_no_tool_call_raises() -> None:
    refusal = SimpleNamespace(
        content=[], stop_reason="refusal", usage=SimpleNamespace(input_tokens=5, output_tokens=1)
    )
    with pytest.raises(AgendaParseError, match="refusal"):
        parse_agenda("x", date(2026, 10, 28), "UTC", model=CLAUDE, client=FakeClient(refusal))


# ------------------------------------------------------------------ Amazon Nova (Converse API)


def converse_answer(tool_input: dict, tokens: tuple[int, int] = (900, 150)) -> dict:
    return {
        "output": {
            "message": {
                "role": "assistant",
                "content": [
                    {
                        "toolUse": {
                            "toolUseId": "tooluse_1",
                            "name": "record_agenda",
                            "input": tool_input,
                        }
                    }
                ],
            }
        },
        "stopReason": "tool_use",
        "usage": {"inputTokens": tokens[0], "outputTokens": tokens[1]},
    }


class FakeRuntime:
    def __init__(self, *answers) -> None:
        self.answers = list(answers)
        self.requests: list[dict] = []

    def converse(self, **request):
        self.requests.append(json.loads(json.dumps(request)))
        return self.answers.pop(0)


NOVA = "us.amazon.nova-lite-v1:0"


def test_nova_uses_converse_with_an_inlined_schema() -> None:
    client = FakeRuntime(converse_answer(GOOD))
    agenda, usage = parse_agenda("Пн 10:00", date(2026, 10, 28), "UTC", model=NOVA, client=client)
    assert agenda.items[0].owner == "Олена"
    assert usage == {"input_tokens": 900, "output_tokens": 150}
    request = client.requests[0]
    assert request["modelId"] == NOVA
    assert "<pasted_text>" in request["messages"][0]["content"][0]["text"]
    schema = request["toolConfig"]["tools"][0]["toolSpec"]["inputSchema"]["json"]
    assert "$ref" not in json.dumps(schema) and "$defs" not in schema


def test_nova_invalid_answer_is_shown_once() -> None:
    client = FakeRuntime(converse_answer({**GOOD, "items": [{"topic": ""}]}), converse_answer(GOOD))
    _, usage = parse_agenda("x", date(2026, 10, 28), "UTC", model=NOVA, client=client)
    assert usage["input_tokens"] == 1800
    result = client.requests[1]["messages"][-1]["content"][0]["toolResult"]
    assert result["status"] == "error" and result["toolUseId"] == "tooluse_1"


def test_nova_without_tool_call_raises() -> None:
    answer = {
        "output": {"message": {"role": "assistant", "content": [{"text": "Sorry"}]}},
        "stopReason": "end_turn",
        "usage": {"inputTokens": 10, "outputTokens": 2},
    }
    with pytest.raises(AgendaParseError, match="end_turn"):
        parse_agenda("x", date(2026, 10, 28), "UTC", model=NOVA, client=FakeRuntime(answer))


def test_cost() -> None:
    usage = {"input_tokens": 5500, "output_tokens": 300}
    assert cost_usd("anthropic.claude-opus-5-5", usage) == pytest.approx(0.028)
    assert cost_usd("anthropic.claude-haiku-5-5", usage) == pytest.approx(0.0007)
    assert cost_usd("us.amazon.nova-lite-v1:0", usage) == pytest.approx(0.000402)
    assert cost_usd("unknown", usage) is None


# ------------------------------------------------------------------ the Lambda handler


@pytest.fixture
def fake_model(monkeypatch):
    verifier = TokenVerifier(POOL_ID, CLIENT_ID, JWKS)
    monkeypatch.setattr(agenda_lambda, "get_verifier", lambda: verifier)
    monkeypatch.setattr(agenda_lambda.settings, "parser_model", "anthropic.claude-opus-5-5")

    def use(*answers) -> FakeClient:
        client = FakeClient(*answers)
        monkeypatch.setattr(agenda_module, "get_client", lambda: client)
        return client

    return use


def event(text: str = "Пн 10:00, синк", token: str | None = None, **body) -> dict:
    return {
        "headers": {"Authorization": f"Bearer {token or make_token('alice')}"},
        "body": json.dumps({"text": text, "today": "2026-10-28", "tz": "Europe/Kyiv", **body}),
        "isBase64Encoded": False,
    }


def test_handler_parses_and_logs_one_line(fake_model) -> None:
    # Read the log line from a handler of our own: independent of how pytest captures stdout.
    lines: list[str] = []
    handler = logging.Handler()
    handler.emit = lambda record: lines.append(record.getMessage())
    agenda_lambda.log.addHandler(handler)
    fake_model(tool_message(GOOD))
    response = agenda_lambda.handler(event())
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["agenda"]["items"][0]["topic"] == "нові тарифи Pro"
    assert body["prompt_version"] == PROMPT_VERSION
    agenda_lambda.log.removeHandler(handler)
    line = json.loads(lines[-1])
    assert line["event"] == "agenda_parsed"
    assert line["user"] == "alice"
    assert line["input_tokens"] == 1000 and line["output_tokens"] == 200
    assert {"model", "prompt_version", "latency_ms", "cost_usd"} <= line.keys()


def test_handler_rejects_missing_or_bad_tokens(fake_model) -> None:
    client = fake_model()
    for headers in ({}, {"authorization": "Bearer nope"}, {"authorization": "Basic abc"}):
        response = agenda_lambda.handler({**event(), "headers": headers})
        assert response["statusCode"] == 401
    assert client.requests == []


def test_handler_rejects_long_text_before_calling_the_model(fake_model) -> None:
    client = fake_model()
    response = agenda_lambda.handler(event("x" * 10_001))
    assert response["statusCode"] == 413
    assert client.requests == []


def test_handler_bad_requests(fake_model) -> None:
    fake_model()
    assert agenda_lambda.handler({**event(), "body": "not json"})["statusCode"] == 400
    assert agenda_lambda.handler(event("   "))["statusCode"] == 400
    assert agenda_lambda.handler(event(today="Monday"))["statusCode"] == 400


def test_handler_no_agenda_is_422(fake_model) -> None:
    refusal = SimpleNamespace(
        content=[], stop_reason="refusal", usage=SimpleNamespace(input_tokens=5, output_tokens=1)
    )
    fake_model(refusal)
    response = agenda_lambda.handler(event())
    assert response["statusCode"] == 422
    assert json.loads(response["body"])["error"] == "no_agenda"


def test_handler_converse_throttling_is_429(fake_model, monkeypatch) -> None:
    from botocore.exceptions import ClientError

    class Throttled:
        def converse(self, **request):
            raise ClientError({"Error": {"Code": "ThrottlingException"}}, "Converse")

    monkeypatch.setattr(agenda_lambda.settings, "parser_model", NOVA)
    monkeypatch.setattr(agenda_module, "get_runtime_client", lambda: Throttled())
    response = agenda_lambda.handler(event())
    assert response["statusCode"] == 429


def test_handler_throttling_is_429(fake_model) -> None:
    request = httpx.Request("POST", "https://bedrock-mantle.us-east-1.api.aws")
    fake_model(
        anthropic.RateLimitError(
            "slow down", response=httpx.Response(429, request=request), body=None
        )
    )
    response = agenda_lambda.handler(event())
    assert response["statusCode"] == 429
    assert json.loads(response["body"])["error"] == "busy"
