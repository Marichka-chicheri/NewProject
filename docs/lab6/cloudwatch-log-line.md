# Lab 6 · CloudWatch log line of a parse

One parse in the deployed app (Paste an agenda → input 1), from the log group
`/new-project/agenda-parser`:

```json
{"event": "agenda_parsed", "user": "04f8d438-00c1-702e-6b57-fad7eb6e116e", "model": "us.amazon.nova-lite-v1:0", "prompt_version": "agenda-v2", "input_chars": 183, "items": 3, "action_items": 1, "input_tokens": 1640, "output_tokens": 801, "latency_ms": 4589, "cost_usd": 0.000291}
```

Model, prompt version, input and output tokens, latency and cost in dollars, plus the Cognito
user (`sub`) and the size of the input; the pasted text itself is not logged. Read with
`aws logs filter-log-events --log-group-name /new-project/agenda-parser --filter-pattern
'"agenda_parsed"'` (or CloudWatch → Log groups in the console).
