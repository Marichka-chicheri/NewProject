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

## Deploy to Azure (Lab 9)

Google Cloud would not start its free trial without a prepayment, so the Lab 9 port is deployed on **Azure** (approved by the instructor); [ADR 0009](docs/adr/0009-azure-deployment.md) has the service mapping and the why, [the Lab 9 report](docs/lab9-report.md) the costs. [`gcp/`](gcp/) (ADR 0008) is the same port for Google Cloud, validated but not applied. Terraform for Azure is in [`azure/`](azure/), its own root module and HCP Terraform workspace (`new-project-azure`, Local execution).

- **Frontend:** Azure Static Web Apps (Free), built with `VITE_API_URL` = the API's URL; the API allows its origin (CORS).
- **API:** Azure Container Apps `spry-api`, the same backend image built with the default Docker target (no Lambda Web Adapter; uvicorn listens on `$PORT`). Runs as its own managed identity, scales to zero (min replicas 0). Public, because the API checks Cognito tokens itself.
- **Database:** Azure Database for PostgreSQL Flexible Server 17, Burstable `B1ms`, 32 GiB. The password is generated by Terraform and kept in Key Vault; the app reads it through its managed identity. The schema comes from the Alembic migrations that run at container start.
- **Registry:** Azure Container Registry Basic (~$5/month, no free tier), pulled with the managed identity.

**What still runs on AWS:** sign-in (Cognito; the Azure API accepts the same ID tokens), the weekly report (it still reads Aurora, not the Azure database) and the agenda parser.

### First deploy

Requires the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), Docker, Node.js and Terraform. No client secret or key is created: Terraform uses your `az login`, the API a managed identity.

1. Get [Azure for Students](https://azure.microsoft.com/free/students) (university e-mail, no card). Create a **budget** (Cost Management → Budgets, $5/month, alerts at 50/90/100 %).
2. `az login`, then `az account show --query id -o tsv` and put the id into [`azure/terraform.tfvars`](azure/terraform.tfvars). Check which regions your subscription may use (policy *Allowed resource deployment regions*) and set `location` to one of them.
3. Register the resource providers once (Terraform does not): `az provider register -n Microsoft.App Microsoft.DBforPostgreSQL Microsoft.ContainerRegistry Microsoft.KeyVault Microsoft.OperationalInsights Microsoft.ManagedIdentity Microsoft.Web` (one name per `-n`; wait until `az provider show -n <name> --query registrationState` says `Registered`).
4. In HCP Terraform create the workspace `new-project-azure` (CLI-driven, **execution mode Local**), then `terraform login`, `cd azure && terraform init && terraform apply` (~10 minutes).
5. `bash azure/deploy.sh`: builds and pushes the image, rolls out the Container App, builds the frontend and uploads it. It reads the public `COGNITO_*` ids from `.env`.
6. For sign-in on the new URL: add the `*.azurestaticapps.net` address to `app_urls` in [`infra/terraform.tfvars`](infra/terraform.tfvars) (pull request).

Check: `<api_url>/api/health` returns `{"status":"ok"}` after a `SELECT 1` on the database; the app, in a private window and signed in, lists meetings.

### Stop or destroy the database

The Azure database **does not pause**: a running B1ms bills ~$0.017/h (~$12.40/month), its 32 GiB storage ~$3.70/month even when stopped, and the registry ~$5/month regardless.

- **Stop** (keeps the data, storage still billed): `az postgres flexible-server stop -g rg-spry -n <db_server>`; start with `start`. **Azure starts it again after 7 days**, so stop it again, or destroy it. The API answers 500 while it is stopped.
- **Destroy** everything in `azure/` (database and its data, registry, Key Vault, Container App, Static Web App): `cd azure && terraform destroy` (or `az group delete -n rg-spry`). Then check Cost Management a day later.

## Deploy to Google Cloud (Lab 9, not applied)

The core of the app (frontend, API, database) can also run on GCP, in `us-central1`; see [ADR 0008](docs/adr/0008-gcp-port.md) for the service mapping and the why, and [the Lab 9 report](docs/lab9-report.md) for the costs. Terraform for it is in [`gcp/`](gcp/), a separate root module with its own HCP Terraform workspace (`new-project-gcp`), so it never touches the AWS state.

- **Frontend:** Firebase Hosting, `https://<project_id>.web.app`. It rewrites `/api/**` to Cloud Run, so the bundle is built with an empty `VITE_API_URL` and the browser stays on one origin ([`frontend/firebase.json`](frontend/firebase.json)).
- **API:** Cloud Run service `spry-api`, the same backend image built with the default Docker target (no Lambda Web Adapter; uvicorn listens on `$PORT`). Runs as its own service account `spry-api`, scales to zero (min instances 0, max 2), public because the API checks Cognito tokens itself.
- **Database:** Cloud SQL PostgreSQL 17 `db-f1-micro`, 10 GB SSD, reached through the Cloud SQL connector socket (`/cloudsql/...`). The password is generated by Terraform and kept in Secret Manager (`spry-db-password`); only `spry-api` can read it. The schema comes from the Alembic migrations that run when the container starts (no data is copied from Aurora).

**What still runs on AWS:** sign-in (Cognito, the GCP API accepts the same ID tokens), the weekly report (EventBridge Scheduler → SQS → Lambda → S3 → SES; it still reads Aurora, not Cloud SQL), and the agenda parser (Lambda + Bedrock, called by the browser directly). `infra/` is unchanged by `gcp/`.

### First deploy

Requires the [gcloud CLI](https://cloud.google.com/sdk/docs/install), Docker, Node.js and Terraform. No service account key is ever created: the laptop uses Application Default Credentials and Terraform impersonates the `spry-terraform` service account.

1. Create the project (e.g. `spry-<name>-2026`) with billing and a $5/month budget alert (50/90/100%) in the console. Put its ID into [`gcp/terraform.tfvars`](gcp/terraform.tfvars).
2. Log in: `gcloud auth login`, `gcloud auth application-default login`, `gcloud config set project <project_id>`, `gcloud auth application-default set-quota-project <project_id>`.
3. Once, as the project Owner: `cd gcp/bootstrap && terraform init && terraform apply -var project_id=<project_id> -var admin_email=<you>` (service accounts, Workload Identity Federation for GitHub; local state).
4. In HCP Terraform, create the workspace `new-project-gcp` (CLI-driven, **execution mode Local**), then `terraform login`, `cd gcp && terraform init && terraform apply`. The first apply takes ~10–15 minutes (Cloud SQL). Cloud Run starts with a placeholder image.
5. `bash gcp/deploy.sh`: builds and pushes the backend image to Artifact Registry, points Cloud Run at it, builds the frontend and deploys it to Firebase Hosting. It reads the public `COGNITO_*` ids from `.env`.
6. For sign-in on the new URL: add `https://<project_id>.web.app` to `app_urls` in [`infra/terraform.tfvars`](infra/terraform.tfvars) (pull request → HCP Terraform applies it to Cognito and the parser's CORS).

Check: `https://<project_id>.web.app/api/health` returns `{"status":"ok"}` after a `SELECT 1` on Cloud SQL; signed in, the meetings list reads from the database.

Later code changes: `bash gcp/deploy.sh` again. Infrastructure changes: edit `gcp/*.tf`, `terraform plan`, `terraform apply`.

### Stop or destroy the database

Cloud SQL **does not pause** like Aurora: a running `db-f1-micro` bills ~$0.0105/h (~$7.70/month) whether anyone uses it or not, and its 10 GB SSD (~$1.70/month) is billed even while stopped.

- **Stop** (keeps the data, storage still billed): set `db_activation_policy = "NEVER"` in `gcp/terraform.tfvars` and `terraform apply`, or `gcloud sql instances patch spry-db --activation-policy=NEVER`. Start again with `ALWAYS`. If you used `gcloud`, put the same value into the tfvars before the next apply, or Terraform will undo it. The API answers 500 while the database is stopped.
- **Destroy** everything in `gcp/` (database and its data, Cloud Run, the registry, the secret, the Hosting site): `cd gcp && terraform destroy`. Deletion protection is off for the lab (`db_deletion_protection`). Then `cd gcp/bootstrap && terraform destroy` for the service accounts and the WIF pool, and check **Billing → Reports** a day later. Deleting the whole project (`gcloud projects delete <project_id>`) also stops everything, but the ID can never be reused.

## Layout

```
backend/    FastAPI app (app/), Alembic migrations (alembic/), tests (tests/)
frontend/   Vite + React + shadcn/ui (src/components/ui is generated by shadcn)
infra/      Terraform (Cognito, reports, agenda parser), CloudFormation templates and deploy scripts (backend, frontend)
azure/      Terraform for the Azure port (Container Apps, PostgreSQL, Static Web Apps), deploy.sh
gcp/        Terraform for the GCP port (Cloud Run, Cloud SQL, Firebase Hosting), bootstrap/ and deploy.sh
```
