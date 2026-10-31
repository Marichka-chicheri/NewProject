"""The agenda-parser Lambda function, behind its own function URL (infra/ai.yml).

Runs outside the VPC: it needs no database, only Bedrock and Cognito's signing keys, both
reachable over the internet without a NAT gateway. It receives text and returns JSON; it never
writes anything. Saving goes through the main API.

POST {"text": "...", "today": "2026-10-28", "tz": "Europe/Kyiv"}
  200 {"agenda": {...}, "model": "...", "prompt_version": "..."}
  400 bad request · 401 no or invalid Cognito ID token · 413 text too long
  422 the model returned no usable agenda · 429 Bedrock is throttling · 502/504 Bedrock failed

The model is PARSER_MODEL: Claude through the Messages API, or Amazon Nova through Converse.
"""

import asyncio
import base64
import json
import logging
import re
import sys
import time
from datetime import date
from functools import cache
from typing import Any

import anthropic
from botocore.exceptions import BotoCoreError, ClientError, ReadTimeoutError

from app.ai.agenda import PROMPT_VERSION, AgendaParseError, cost_usd, parse_agenda
from app.auth import InvalidTokenError, TokenVerifier
from app.config import settings
from app.lambda_runtime import serve

log = logging.getLogger("agenda-parser")
log.setLevel(logging.INFO)
log.propagate = False
if not log.handlers:
    # One JSON object per line, so CloudWatch Logs Insights can query the fields.
    _stream = logging.StreamHandler(sys.stdout)
    _stream.setFormatter(logging.Formatter("%(message)s"))
    log.addHandler(_stream)

TZ_PATTERN = re.compile(r"^[A-Za-z0-9_+\-/]{1,64}$")

# One event loop for the life of the instance: the verifier caches the keys and its lock.
_loop = asyncio.new_event_loop()


@cache
def get_verifier() -> TokenVerifier:
    # No COGNITO_JWKS here: outside the VPC the function downloads the keys from Cognito.
    return TokenVerifier(
        settings.cognito_user_pool_id, settings.cognito_client_id, settings.cognito_jwks
    )


class HttpError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def _response(status: int, body: dict[str, Any]) -> dict[str, Any]:
    # CORS headers are added by the function URL itself (infra/ai.yml).
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def verify_cognito_token(authorization: str) -> dict[str, Any]:
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise HttpError(401, "unauthorized", "Sign in to use the agenda parser")
    try:
        return _loop.run_until_complete(get_verifier().verify(token.strip()))
    except InvalidTokenError:
        raise HttpError(401, "unauthorized", "Invalid or expired token") from None


def read_request(event: dict[str, Any]) -> tuple[str, date, str]:
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode()
    try:
        body = json.loads(raw)
        text, today, tz = body["text"], date.fromisoformat(body["today"]), body["tz"]
    except ValueError, KeyError, TypeError:
        raise HttpError(
            400, "bad_request", 'Send JSON: {"text": "...", "today": "YYYY-MM-DD", "tz": "..."}'
        ) from None
    if not isinstance(text, str) or not text.strip():
        raise HttpError(400, "bad_request", "The text is empty")
    if not isinstance(tz, str) or not TZ_PATTERN.match(tz):
        raise HttpError(400, "bad_request", "tz must be a time zone name such as Europe/Kyiv")
    # Checked before the model is called: a long text costs money even when it fails.
    if len(text) > settings.parser_max_chars:
        raise HttpError(
            413,
            "too_long",
            f"The text is {len(text):,} characters; the limit is {settings.parser_max_chars:,}",
        )
    return text, today, tz


def handler(event: dict[str, Any], context: Any = None) -> dict[str, Any]:
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    try:
        user = verify_cognito_token(headers.get("authorization", ""))
        text, today, tz = read_request(event)
    except HttpError as e:
        return _response(e.status, {"error": e.code, "message": e.message})

    model = settings.parser_model
    record: dict[str, Any] = {
        "event": "agenda_parsed",
        "user": user["sub"],
        "model": model,
        "prompt_version": PROMPT_VERSION,
        "input_chars": len(text),
    }
    started = time.monotonic()
    usage = {"input_tokens": 0, "output_tokens": 0}
    try:
        agenda, usage = parse_agenda(text, today, tz, model=model)
        status, body = (
            200,
            {
                "agenda": agenda.model_dump(mode="json"),
                "model": model,
                "prompt_version": PROMPT_VERSION,
            },
        )
        record["items"] = len(agenda.items)
        record["action_items"] = len(agenda.action_items)
    except AgendaParseError as e:
        usage = e.usage
        status, body = 422, {"error": "no_agenda", "message": str(e)}
    except anthropic.RateLimitError:
        status, body = 429, {"error": "busy", "message": "The model is busy; try again shortly"}
    except anthropic.APITimeoutError:
        status, body = 504, {"error": "timeout", "message": "The model took too long to answer"}
    except anthropic.APIError as e:
        log.exception("bedrock call failed")
        status, body = 502, {"error": "upstream", "message": f"The model call failed: {e}"}
    except ClientError as e:  # the Converse API (Nova and other non-Claude models)
        code = e.response.get("Error", {}).get("Code", "")
        if code in ("ThrottlingException", "TooManyRequestsException"):
            status, body = 429, {"error": "busy", "message": "The model is busy; try again shortly"}
        elif code == "ModelTimeoutException":
            status, body = 504, {"error": "timeout", "message": "The model took too long"}
        else:
            log.exception("bedrock call failed")
            status, body = 502, {"error": "upstream", "message": f"The model call failed: {code}"}
    except ReadTimeoutError:
        status, body = 504, {"error": "timeout", "message": "The model took too long to answer"}
    except BotoCoreError as e:
        log.exception("bedrock call failed")
        status, body = 502, {"error": "upstream", "message": f"The model call failed: {e}"}

    if status != 200:
        record["event"] = "agenda_parse_failed"
        record["error"] = body["error"]
    # Item 4 of the submission: model, prompt version, tokens, latency and cost of one parse.
    log.info(
        json.dumps(
            {
                **record,
                **usage,
                "latency_ms": int((time.monotonic() - started) * 1000),
                "cost_usd": cost_usd(model, usage),
            }
        )
    )
    return _response(status, body)


if __name__ == "__main__":
    serve(handler)
