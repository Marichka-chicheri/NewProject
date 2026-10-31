# Meetings App

List, create, and delete meetings with participants. FastAPI + PostgreSQL backend, React + shadcn/ui frontend, all run with Docker Compose. See [SPEC.md](SPEC.md) for the full specification.

## Quick start

Requires Docker.

```sh
make up      # creates .env from .env.example, builds and starts everything
make seed    # optional: sample participants and meetings
```

- App: http://localhost:3000
- API docs: http://localhost:8000/api/docs

If port 5432 is already in use on your machine, set `DB_PORT` in `.env` (e.g. `DB_PORT=5433`).

## Common commands

Run `make` to list all targets. The most used:

| Command | What it does |
|---|---|
| `make up` / `make down` | Start / stop the stack |
| `make logs s=backend` | Follow logs of one service |
| `make test` | Backend tests (in the backend container, against `<db>_test`) |
| `make lint` / `make format` | Ruff + oxlint/Prettier |
| `make migration m="..."` | Autogenerate an Alembic migration |
| `make psql` | Open a psql shell |
| `make clean` | Stop and delete the database volume |

## Local development without rebuilding images

Requires [uv](https://docs.astral.sh/uv/) and Node.js.

```sh
make install        # uv sync + npm install
make dev-backend    # Postgres in Docker, API on :8000 with reload
make dev-frontend   # Vite on :5173, proxies /api to :8000
```

## Deploy to AWS

The application is deployed with CloudFormation and shell scripts in [`infra/`](infra/) to `us-east-1` by default (`AWS_REGION` in `.env`); Cognito, the weekly report and the agenda parser are Terraform, see [Infrastructure as code](#infrastructure-as-code-terraform):

- **Backend** (`make deploy-backend`): the backend container on AWS Lambda (via [Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter), so the FastAPI app runs unchanged), exposed through a public **Lambda function URL**, and its PostgreSQL 17 database on **Aurora Serverless v2 scaling between 0 and 1 ACU**. After 5 idle minutes the database pauses and costs only storage; the first request after that waits about 15 seconds while it resumes. The function runs in the database's private subnets; there is no NAT gateway, load balancer or public IP.
- **Frontend** (`make deploy-frontend`): the app, built with `VITE_API_URL` set to the function URL, in a private S3 bucket behind CloudFront on **pay-as-you-go** pricing (no flat-rate plan; `PriceClass_100`). The browser calls the function URL directly; the deploy adds the CloudFront address to the backend's CORS origins.

1. Put the credentials of an IAM user into `.env` (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`; see `.env.example` for the optional settings), and the Cognito IDs from `make infra-output` (`COGNITO_*`). `.env` is gitignored.
2. `make deploy` (backend, then frontend). It prints the app and API URLs. The first run takes about 20 minutes (database and CloudFront distribution); later runs take a few minutes. Deploy the two parts separately with `make deploy-backend` / `make deploy-frontend`.
3. `make destroy-frontend` and `make destroy-backend` delete everything except a final database snapshot.

Requires Docker, Node.js and the AWS CLI (and the Terraform CLI for `make infra-plan`). `make infra-lint` checks the templates and the Terraform formatting.

### Paste an agenda (Claude on Amazon Bedrock)

A meeting's agenda can be typed, or pasted as free text (an email, a chat message, notes) and
parsed by Claude on Bedrock into a pre-filled form that the user checks and saves. The parser is a
separate Lambda function **outside the VPC** (it needs no database), reusing the backend image;
saving goes through the normal API. See [ADR 0006](docs/adr/0006-llm-agenda-parsing.md) and the
[container diagram](docs/architecture/c4-container.md).

1. Make sure Anthropic models are enabled for the account (Bedrock → Model catalog, `us-east-1`),
   and that your IAM user may call `bedrock-mantle:CreateInference`.
2. `make llm-hello` — the first call from the laptop; `make parse TEXT="..."` — the parser alone.
3. The parser, its function URL and a 5 USD/month AWS Budgets alarm are Terraform (`infra/ai.tf`):
   merge to `main` and HCP Terraform applies them. `make deploy-backend` (new image + migration)
   also moves the parser to the new image; `make deploy-frontend` builds the frontend against the
   parser URL.
4. The deployed model is `parser_model` in `infra/terraform.tfvars` (`PARSER_MODEL` in `.env` for `make parse` from the laptop): `us.amazon.nova-lite-v1:0` (Amazon Nova, Converse API) by default,
   `anthropic.claude-opus-5-5` for Claude (Messages API) once Anthropic models are enabled. Logs, one JSON
   line per parse with tokens, latency and cost: `aws logs tail /<PROJECT_NAME>/agenda-parser`.

### Infrastructure as code (Terraform)

Cognito ([`auth.tf`](infra/auth.tf)), the weekly report ([`reports.tf`](infra/reports.tf)) and the agenda parser with its budget alarm ([`ai.tf`](infra/ai.tf)) are Terraform, one root module in [`infra/`](infra/). The backend, the database and the frontend are still CloudFormation; Terraform reads the backend stack's outputs. See [ADR 0007](docs/adr/0007-terraform.md) for the why, and [the migration runbook](docs/lab7-migration.md) for how the existing resources were adopted.

- **Who applies:** HCP Terraform (workspace `new-project-dev`, connected to this repository, working directory `infra`), with short-lived AWS credentials from an OIDC role. Nobody applies from a laptop and the Makefile has no `terraform apply`.
- **How to change it:** edit `infra/*.tf`, open a pull request, read the plan in the check, merge. HCP Terraform applies after the merge.
- **From the laptop (read-only):** `terraform login` once, then `make infra-init`, `make infra-fmt`, `make infra-validate`, `make infra-plan` (a speculative plan, nothing applied), `make infra-output`.
- **Variables:** non-secret values in [`infra/terraform.tfvars`](infra/terraform.tfvars); the Google client secret is a sensitive variable of the workspace. After the frontend gets a new address (`make deploy-frontend`, `make add-domain`), add it to `app_urls`.
- **Two roads:** GitHub Actions deploys the application (`make deploy-backend` also moves the report builder and the parser to the new image), HCP Terraform deploys the infrastructure. When a change needs both, merge the Terraform pull request first.

### Custom domain

Once everything is deployed, set the domain in `.env` and attach it:

```sh
DOMAIN_NAME=app.example.com
HOSTED_ZONE_ID=Z0123456789ABC   # optional: only if the domain's DNS is in Route 53
```

```sh
make add-domain
```

This requests an ACM certificate in `us-east-1` (the only region CloudFront accepts), adds the domain to the CloudFront distribution and to the backend's CORS origins. With `HOSTED_ZONE_ID`, the validation and alias records are created in Route 53 for you. Without it, the command prints the validation CNAME to add at your DNS provider, waits for the certificate, and then prints the CNAME that points the domain at CloudFront. Later `make deploy` runs keep the domain. `make remove-domain` detaches it again (to switch domains: `make remove-domain`, change `DOMAIN_NAME`, `make add-domain`).

### Tags

Every AWS resource that supports tags is tagged `PROJECT_NAME=<PROJECT_NAME>` (in the templates as `Key: PROJECT_NAME, Value: !Ref ProjectName`, plus stack tags and tags on the SSM parameter). Find the whole app with Resource Groups & Tag Editor, and split out its costs in Billing once `PROJECT_NAME` is activated as a cost allocation tag. `APP_NAME` in older `.env` files still works as the project name.

## Layout

```
backend/    FastAPI app (app/), Alembic migrations (alembic/), tests (tests/)
frontend/   Vite + React + shadcn/ui (src/components/ui is generated by shadcn)
infra/      Terraform (Cognito, reports, agenda parser), CloudFormation templates and deploy scripts (backend, frontend)
```
