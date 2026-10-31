"""`make llm-hello`: the first Bedrock call from the laptop (lab Part 1). Prints the answer,
stop_reason and usage. Uses your usual AWS credentials from .env."""

import sys

from app.ai.agenda import get_client, get_runtime_client, is_claude
from app.config import settings


def list_models() -> None:
    """`make llm-models`: which Claude model IDs this AWS account can see and call."""
    print("== bedrock-mantle: GET /v1/models")
    try:
        body = get_client().get("/v1/models", cast_to=object)
        for model in body.get("data", []):
            print(" ", model.get("id"), "-", model.get("display_name", ""))
    except Exception as error:  # the endpoint may not offer the list
        print("  not available:", type(error).__name__, str(error)[:300])

    import boto3

    bedrock = boto3.client("bedrock", region_name=settings.aws_region)
    print("== Bedrock catalog: Anthropic and Amazon text models, with this account's access")
    summaries = [
        s
        for provider in ("anthropic", "amazon")
        for s in bedrock.list_foundation_models(byProvider=provider, byOutputModality="TEXT")[
            "modelSummaries"
        ]
    ]
    for summary in summaries:
        model_id = summary["modelId"]
        try:
            availability = bedrock.get_foundation_model_availability(modelId=model_id)
            status = availability.get("agreementAvailability", {}).get("status", "?")
            status += " / " + availability.get("authorizationStatus", "?")
        except Exception as error:
            status = type(error).__name__
        print(f"  {model_id:55} {summary.get('modelLifecycle', {}).get('status', '')}  {status}")


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    if "--models" in sys.argv:
        list_models()
        return
    question = "In one sentence: what is an ISO week?"
    print("model:", settings.parser_model)
    if not is_claude(settings.parser_model):
        # Amazon Nova and other models: the Converse API.
        resp = get_runtime_client().converse(
            modelId=settings.parser_model,
            messages=[{"role": "user", "content": [{"text": question}]}],
            inferenceConfig={"maxTokens": 200},
        )
        print(resp["output"]["message"]["content"][0]["text"])
        print(resp["stopReason"], resp["usage"]["inputTokens"], resp["usage"]["outputTokens"])
        return
    msg = get_client().messages.create(
        model=settings.parser_model,
        max_tokens=1024,
        output_config={"effort": "low"},  # short, cheap answers
        messages=[{"role": "user", "content": question}],
    )
    print(next(b.text for b in msg.content if b.type == "text"))
    print(msg.stop_reason, msg.usage.input_tokens, msg.usage.output_tokens)


if __name__ == "__main__":
    main()
