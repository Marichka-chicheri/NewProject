# Container diagram (C4, level 2)

Lab 6 update of the Lab 1 container diagram. Lab 1 planned Django on GCP; the system as built
runs on AWS (Labs 2–5). This diagram shows the system as built, plus the Paste an agenda
feature from Lab 6 (marked **NEW**).

Two paths for one feature:

1. **Parse** — browser → agenda parser (Lambda outside the VPC) → Amazon Bedrock. Text in, JSON
   out; nothing is written.
2. **Save** — browser → Meetings API (Lambda in the VPC) → Aurora. The same validated endpoint
   as a hand-typed agenda; the parser's suggestion is stored next to it in `ai_suggestion`.

![Container diagram](c4-container.png)

Source: [`c4-container.mmd`](c4-container.mmd). Re-render with
`npx -p @mermaid-js/mermaid-cli mmdc -i docs/architecture/c4-container.mmd -o docs/architecture/c4-container.png -b white -w 1800`.

```mermaid
flowchart TB
    member["<b>Member</b><br/>[Person]<br/>Plans meetings and their agendas"]

    subgraph browser["User's browser"]
        spa["<b>Frontend SPA</b><br/>[Container: React + Vite]<br/>Calendar, meeting forms,<br/>Paste an agenda screen"]
    end

    subgraph aws["AWS account · us-east-1 · tag PROJECT_NAME=new-project"]
        cdn["<b>Static site</b><br/>[Container: S3 + CloudFront]<br/>Serves the SPA"]

        subgraph novpc["Outside the VPC · no NAT"]
            parser["<b>Agenda parser</b> · NEW<br/>[Container: Lambda, backend image,<br/>app.ai.agenda_lambda.handler]<br/>Text in, agenda JSON out.<br/>Checks the Cognito token. Never writes."]
            mailer["<b>Report mailer</b><br/>[Container: Lambda]<br/>Emails the weekly CSV"]
        end

        subgraph vpc["VPC · private subnets"]
            api["<b>Meetings API</b><br/>[Container: FastAPI on Lambda<br/>+ Lambda Web Adapter]<br/>Validates and writes everything,<br/>incl. POST /meetings/{id}/agenda"]
            builder["<b>Report builder</b><br/>[Container: Lambda]<br/>Builds the weekly CSV"]
            db[("<b>Database</b><br/>[Container: Aurora PostgreSQL<br/>Serverless v2]<br/>meetings.agenda JSONB,<br/>meetings.ai_suggestion JSONB")]
        end

        queue["<b>Report requests</b><br/>[SQS + DLQ]<br/>fed by EventBridge Scheduler"]
        bucket["<b>Reports bucket</b><br/>[S3]"]
    end

    subgraph ext["AWS managed services"]
        cognito["<b>Amazon Cognito</b><br/>Sign-in, ID tokens, JWKS"]
        bedrock["<b>Amazon Bedrock</b> · NEW<br/>Amazon Nova Lite via Converse<br/>(Claude via the Messages API<br/>once enabled)"]
        ses["<b>Amazon SES</b>"]
        budgets["<b>AWS Budgets</b> · NEW<br/>5 USD / month alarm by email"]
    end

    member -- "Uses" --> spa
    spa -- "Loads from [HTTPS]" --> cdn
    spa -- "Signs in [OIDC]" --> cognito

    spa == "1 · PARSE: POST text, today, tz<br/>+ ID token [HTTPS, function URL]" ==> parser
    parser == "2 · converse, tool record_agenda<br/>[HTTPS, IAM role]" ==> bedrock
    parser -. "Fetches signing keys [HTTPS]" .-> cognito

    spa == "3 · SAVE: POST /api/meetings/{id}/agenda<br/>+ ai_suggestion [HTTPS, function URL]" ==> api
    api == "4 · Writes agenda + ai_suggestion [SQL]" ==> db

    builder -- "Reads [SQL]" --> db
    queue -- "Triggers" --> builder
    builder -- "Writes CSV" --> bucket
    bucket -- "ObjectCreated" --> mailer
    mailer -- "Sends" --> ses

    classDef person fill:#ffe9d6,stroke:#e8743b,color:#5a2a0c
    classDef container fill:#fff3e6,stroke:#e8743b,color:#5a2a0c
    classDef newc fill:#fde4ec,stroke:#d6336c,stroke-width:3px,color:#5c0d2a
    classDef store fill:#e3edff,stroke:#2f62d6,color:#123
    classDef external fill:#f3e6ff,stroke:#8a3ad6,color:#3a1060

    class member person
    class spa,cdn,api,builder,mailer,queue,bucket container
    class parser,bedrock,budgets newc
    class db store
    class cognito,ses external
```
