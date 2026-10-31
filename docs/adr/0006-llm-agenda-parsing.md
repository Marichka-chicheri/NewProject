# 6. Parse pasted agendas with Claude on Bedrock, outside the VPC, without writing

- Status: accepted; amended 2026-10-31 (model: Amazon Nova until Claude is enabled)
- Date: 2026-10-28
- Lab: 6 (Paste an agenda)

## Context

Agendas reach our users as text, not forms: an email from a manager, a chat message, a few lines
of notes, in Ukrainian or English, with names, durations and relative dates ("by Friday"). Typing
them into the agenda form by hand is the step users skip. We want a **Paste an agenda** screen:
the user pastes the text, a model turns it into the agenda schema, and the user checks the
pre-filled form and saves it.

Constraints:

- **No NAT gateway.** The API and the database live in private subnets with no internet access
  (Lab 4). A NAT gateway costs ~$32 a month before any traffic; an interface VPC endpoint
  ~$7.30 per AZ a month (~$14.60 for our two subnets).
- **Cost.** Every parse costs tokens. An open endpoint that calls a model is a wallet without a
  lock.
- **The text comes from outside.** Pasted emails can contain instructions aimed at the model
  ("ignore your instructions…"). The model's output is untrusted, can be wrong while looking
  right, and is different on every run.
- **Bedrock specifics.** Claude Opus 5.5 on Bedrock does not accept a forced `tool_choice`, and
  the Messages API on Bedrock has no structured outputs, so a valid answer cannot be guaranteed
  by the API; it has to be checked.

## Decision

- **Model:** Claude Opus 5.5 (`anthropic.claude-opus-5-5`) through the Anthropic Messages API on
  Bedrock (`bedrock-mantle`), `effort: low`. The model ID is configuration (`PARSER_MODEL`), so
  Haiku 5.5 can replace it without a code change if the test set says it is good enough.
- **The contract is a schema.** The model answers by calling one tool, `record_agenda`, whose
  input schema is `ParsedAgenda` (Pydantic). Every answer is validated; an invalid one is shown
  to the model once with the validation error, then the parse fails with a clear error. Fields the
  text does not mention stay `null` ("never invent a value"). Today's date and the user's time
  zone are in the prompt, so relative dates resolve to the right week. The pasted text is
  delimited (`<pasted_text>`) and the system prompt says it is data, not instructions.
- **A separate function, outside the VPC.** The parser receives text and returns JSON; it needs
  no database. It runs as its own Lambda function (the backend's container image, handler
  `app.ai.agenda_lambda.handler`, 512 MB, 30 s) with no `VpcConfig`, so it reaches Bedrock and
  Cognito over the internet with no NAT and no endpoint, and costs nothing while idle. Its role
  may only write logs and call `bedrock-mantle:CreateInference`.
- **Authenticated, limited.** The function URL is public (`AuthType: NONE`, CORS for our sites,
  POST only), but the handler verifies the Cognito ID token (JWKS downloaded from Cognito) and
  answers 401 otherwise. Texts over 10,000 characters are rejected with 413 before the model is
  called.
- **The model never writes.** The browser shows the result as the normal agenda form, with every
  model-filled field marked *suggested* until the user touches it. Saving goes through the
  existing API (`POST /api/meetings/{id}/agenda`) with its validation and ownership checks. The
  request also carries what the model suggested, the pasted text, the model and the prompt
  version; the API stores them in `meetings.ai_suggestion` (JSONB) next to the final agenda.
- **Observability.** One JSON log line per parse: user, model, prompt version, input and output
  tokens, latency and cost in dollars at list prices.
- **A $5 monthly AWS Budgets alarm** by email, in the same stack.

### Amendment, 2026-10-31: Amazon Nova until Claude is available

Bedrock refuses every Anthropic model on our account (`AccessDeniedException: … is not
available for this account`; agreement status `NOT_AVAILABLE`, the use case form never appears;
an AWS support case is open). To keep the feature moving, the
parser runs on **Amazon Nova Lite** (`us.amazon.nova-lite-v1:0`), a first-party model that needs
no agreement, through the provider-neutral **Converse API** (`bedrock-runtime`).

- The provider is chosen by the model ID: `anthropic.*` goes through the Messages API, anything
  else through Converse. Same system prompt, same `record_agenda` tool (its schema with `$ref`s
  inlined), same validation and single retry, same log line. Switching back to Claude is one line
  in `.env` (`PARSER_MODEL=anthropic.claude-opus-5-5`) and `make deploy-ai`.
- Converse gives what Part 1 of the lab promised: change `modelId`, keep the code. The price is
  the lowest common denominator: no `effort`, provider-specific features arrive later or never.
- The role also gets `bedrock:InvokeModel` on Nova's inference profile and foundation models.
- Nova Lite costs ~$0.06 / $0.24 per 1M tokens: ~$0.00015 per parse, ~70× less than Opus 5.5.
  Whether it is good enough on our five inputs (Ukrainian, owners, relative dates, injection) is
  in the Lab 6 report.

## Alternatives considered

| Alternative | Why it lost |
|---|---|
| **Call Bedrock from the existing API through a `bedrock-mantle` interface VPC endpoint** | Puts a slow (2–8 s), non-deterministic, paid call on the request path of the API that holds the database credentials, and adds ~$14.60 a month for the endpoint in two AZs, more than a month of parsing at our expected volume. Nothing in parsing needs the database. It becomes the right choice for a chat that reads meetings (the *Ask Spry* stretch goal). |
| **The Claude API directly (api.anthropic.com) instead of Bedrock** | Same model and request shape, but an API key to store, rotate and protect in Lambda, and a second bill outside AWS Budgets and cost allocation tags. Bedrock authorises the call with the function's IAM role and logs it in CloudTrail. |
| **A regular-expression parser** | Free, fast and deterministic, and good for one fixed format ("1) topic — owner, 15 min"). Real agendas come in any format and two languages; owners, durations and relative dates in free text ("Taras до п'ятниці збирає…") need understanding, not patterns. We would keep adding rules forever. |

## Consequences

- **Cost per parse.** Typically ~1,100–1,500 input tokens (system prompt and tool schema are
  most of it) and ~200–400 output tokens: about **$0.01 with Opus 5.5** and **$0.0003 with Haiku
  5.5** at list prices. 20 organisations × 30 agendas a week ≈ 2,600 parses a month ≈ $30 a month
  with Opus, under $1 with Haiku. The measured numbers are in the Lab 6 report.
- **Logged:** per parse, the JSON line above (no pasted text in the logs). Per saved agenda, the
  suggestion, the text, the model and the prompt version in `ai_suggestion`. The difference
  between the suggestion and the saved agenda is our quality signal and the evaluation set for the
  next prompt version.
- **When Bedrock is down or throttling** the parser answers 429/502/504 and the screen says so;
  the user types the agenda by hand in the same form. Everything else in Spry (meetings, agendas,
  reports) does not depend on Bedrock and keeps working.
- **Prompt injection is limited by design, not by the prompt.** Even if the model obeys injected
  text, it can only change the suggestion shown to this user, who reviews it before saving; the
  function has no database access and no write path, and the API only lets users write their own
  meetings.
- **Open points.** The IAM resource is `"*"`; it should be narrowed to the model(s) we use once we
  settle on one. The function has no per-user rate limit beyond Cognito sign-in and the budget
  alarm; reserved concurrency or a per-user counter would cap a runaway client. The handler runs
  its own runtime loop (as the report builder), because the shared image has no Lambda runtime
  client.
