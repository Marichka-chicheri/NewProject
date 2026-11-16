# 8. Run the core of Spry on Google Cloud: Firebase Hosting, Cloud Run, Cloud SQL

- Status: accepted
- Date: 2026-11-11
- Lab: 9 (Google Cloud)

## Context

Spry runs on AWS (Labs 3–8) and its infrastructure is in Terraform (ADR 0007). Lab 9 asks what it
would take to run the same system on a second cloud, and what it would cost there. The question is
not "lift everything", but which pieces are worth moving, which have a direct equivalent, and which
are cheaper or safer to leave where they are.

The constraints that decide most rows:

- **The bill when nobody uses it.** On AWS the whole app costs ≈ $0.30/month idle, because Lambda
  and Aurora Serverless v2 (0 ACU) both go to zero. Anything we pick on GCP should be judged on
  the same four traffic profiles as Lab 4.
- **The code should not fork.** One backend image, one frontend build, one Alembic history.
- **Real users are in the Cognito pool.** Cognito cannot export password hashes, so moving sign-in
  means every user resets their password.
- **No long-lived keys**, the same rule ADR 0007 applied to AWS.

## Decision

### Service mapping

| # | AWS today | GCP equivalent | Difference that matters | Decision |
|---|---|---|---|---|
| 1 | S3 + CloudFront (+ WAF) | Firebase Hosting | Bucket, CDN, TLS and SPA rewrite in one product; `/api/**` can be rewritten to Cloud Run, so the browser talks to one origin and CORS disappears. No WAF: Cloud Armor needs an external load balancer (~$18/month minimum). | **Replace**; WAF **dropped** |
| 2 | Lambda + function URL (FastAPI via Lambda Web Adapter) | Cloud Run | Runs any container that listens on `$PORT`: the Lambda layer goes away. Up to 80 concurrent requests per instance instead of 1, so the DB pool can be > 1. Scales to zero like Lambda. | **Replace** |
| 3 | ECR | Artifact Registry | 0.5 GB free; a cleanup policy keeps the last three images. | **Replace** |
| 4 | Aurora Serverless v2, 0–1 ACU, pauses after 5 min | Cloud SQL PostgreSQL 17, `db-f1-micro`, 10 GB SSD | **Does not pause.** Bills ~$7.67/month of compute whenever it is running, plus storage even when stopped. Same engine, so no code change. AlloyDB is the Aurora look-alike but starts far above our size. | **Replace** (see "Database" below) |
| 5 | DynamoDB | Firestore | Spry does not use DynamoDB (the Terraform state lock it is often used for lives in HCP Terraform). | **Drop** (nothing to move) |
| 6 | Cognito + Google sign-in | Identity Platform (50k MAU free) | Would need every user to re-register or reset; the frontend's OIDC code would change. | **Keep on AWS**; Cloud Run validates Cognito ID tokens itself |
| 7 | EventBridge Scheduler (weekly report) | Cloud Scheduler (3 jobs free) | Equivalent. | **Keep on AWS** (stretch) |
| 8 | SQS (report requests + DLQ) | Pub/Sub, or Cloud Tasks | Pub/Sub is fan-out with push subscriptions; Cloud Tasks is the closer match to "one queue, one worker, retries". | **Keep on AWS** (stretch) |
| 9 | S3 event → Lambda | Cloud Storage + Eventarc → Cloud Run | Equivalent, one more product (Eventarc) in the middle. | **Keep on AWS** (stretch) |
| 10 | SES | none from Google | Google sells no transactional e-mail; options are SendGrid, Mailgun, Resend, or keep SES. | **Keep SES** (see "E-mail" below) |
| 11 | Bedrock (agenda parser, Nova Lite / Claude) | Vertex AI (Gemini; Claude via Model Garden) | The trial credit does not cover partner models (Claude). The parser is a stateless function the browser calls directly; it has no reason to sit next to the database. | **Keep on AWS**; prompt tried in Vertex AI Studio (Part 4) |
| 12 | SSM Parameter Store / Secrets Manager | Secret Manager (6 active versions free) | Cloud Run reads a secret into an env var natively (`secret_key_ref`); per-secret IAM. | **Replace** (DB password) |
| 13 | CloudWatch Logs | Cloud Logging (50 GiB/month free) | Cloud Run's stdout goes there with no configuration. | **Replace** (automatic) |
| 14 | IAM roles (Lambda execution role, OIDC role for HCP Terraform) | Service accounts + IAM roles; Workload Identity Federation | A service account is an identity *and* a resource. The API has its own SA (`spry-api`), not the default compute SA; Terraform has its own (`spry-terraform`) with seven roles, no Owner/Editor. | **Replace** |
| 15 | Terraform `aws` provider, workspace `new-project-dev` | `google` / `google-beta` providers, workspace `new-project-gcp` | Separate root module `gcp/`, separate state: a GCP plan can never touch Cognito or the reports bucket. | **Replace** (in addition) |
| 16 | Route 53 + ACM (custom domain) | Firebase Hosting custom domain (free certificate) | Possible later; the lab uses `<project>.web.app`. | **Drop** for now |

### Database

Four options were on the table:

| Option | Latency from Cloud Run | Bill (idle / 24/7) | Code change |
|---|---|---|---|
| Cloud SQL f1-micro running 24/7 | same region, Unix socket, ~1 ms | $9.40 / $9.40 | none |
| **Cloud SQL f1-micro, stopped when not in use** | same | **$1.70** / $9.40 | none |
| Firestore | same region | $0 / $0 within the free daily quota | rewrite models, queries and migrations (meetings ↔ participants is relational) |
| Keep Aurora on AWS, cross-cloud | us-central1 → us-east-1 ≈ 30 ms per round trip, several per request | $0.30 + egress on both sides + a public Aurora endpoint, or a VPC connector + Cloud NAT with a static IP (~$30+/month) | none, but Aurora must leave its private subnets |

**Chosen: Cloud SQL PostgreSQL 17, `db-f1-micro`, 10 GB SSD, us-central1, stopped between demos**
(`db_activation_policy = "NEVER"` in `gcp/terraform.tfvars`, see the README). It is the only
option with no code change and no network hole. Firestore is how the GCP bill would really get to
$0, but it is a rewrite of the data layer, not a port. Cross-cloud keeps the database where it is
and pays for it on every query (latency) and every month (egress, NAT).

Connection: the Cloud SQL connector mounted into Cloud Run (`/cloudsql/<connection name>`), public
IP with **no** authorized networks, TLS only. No VPC connector, no private services access. The
password is generated by Terraform (`random_password`), stored in Secret Manager, and readable
only by `spry-api`; `app/config.py` builds `DATABASE_URL` from the socket path and `DB_PASSWORD`.

**Data: migrations, not pg_dump.** The container runs `alembic upgrade head` on start, as it does
on Lambda, so the GCP database gets the same schema from the same history. The Aurora data is
test data, and Aurora is in private subnets with no bastion, so a `pg_dump` would mean opening it
up for one copy. If real data had to move: a temporary EC2 bastion in the Aurora VPC,
`pg_dump -Fc`, then `pg_restore` through `cloud-sql-proxy`, with the app read-only in between.

### E-mail

The weekly report stays on AWS, so it **keeps SES** and needs no API key at all: the report
Lambda's IAM role is allowed `ses:SendRawEmail`. If the sender ever moves to GCP (Cloud Scheduler →
Cloud Run job), it should still call SES, with an AWS role it assumes through
`AssumeRoleWithWebIdentity` using its service account's Google-signed ID token (no key on either
side). Only if we left AWS completely would we switch to a provider such as Mailgun or SendGrid;
its API key would then live in **Secret Manager** as `spry-email-api-key`, readable only by the
report job's service account and injected the same way as `DB_PASSWORD` — never in `.env`, the
image, or Terraform variables.

### What we do not move, and why

- **Sign-in (Cognito).** Users would have to reset their passwords, and the frontend's OIDC
  configuration would change, for no gain in this lab. Cloud Run is public and the API checks the
  Cognito ID token itself (`app/auth.py`); the only anonymous endpoint is `/api/health`.
- **The weekly report (EventBridge → SQS → Lambda → S3 → SES).** Four services that work, and SES
  has no Google equivalent. **Known consequence:** the report reads Aurora, so while the GCP
  deployment is the one in use, the report describes AWS's data, not GCP's. Acceptable for a
  lab-length experiment; moving the report is the first stretch goal if GCP became the main site.
- **The agenda parser (Bedrock).** Stateless, called by the browser, cents per month, and Claude on
  Vertex is not covered by the trial credit.
- **WAF and the custom domain.** No cheap WAF without a load balancer; `<project>.web.app` is
  enough for a demo.

### Identity and keys

- `gcp/bootstrap/` (local state, applied once by the project Owner) creates the APIs IAM needs, the
  `spry-terraform` SA with Cloud Run Admin, Cloud SQL Admin, Artifact Registry Administrator,
  Secret Manager Admin, Service Usage Admin, Service Account User **and Firebase Admin** (not in
  the lab's list, needed to add Firebase and create the Hosting site), the `spry-api` SA with Cloud
  SQL Client, and a Workload Identity pool + OIDC provider for `token.actions.githubusercontent.com`
  whose attribute condition checks the **numeric** owner and repository IDs.
- The runtime SA lives in bootstrap because granting it a project-level role (Cloud SQL Client has
  no per-instance form) needs Project IAM Admin, which the Terraform SA deliberately lacks: with it,
  Terraform could grant itself Owner.
- The laptop runs `gcloud auth application-default login` and Terraform impersonates
  `spry-terraform` (Service Account Token Creator for the owner's account only). CI would
  authenticate with `google-github-actions/auth` and the WIF provider. **No service account keys
  exist.**
- HCP Terraform workspace `new-project-gcp` is in **Local** execution mode: it stores the state and
  the lock, the plan runs on the laptop with the ADC token. Remote execution would need HCP
  Terraform's own GCP dynamic credentials (a second WIF provider for `app.terraform.io`); left as
  a stretch.

## Alternatives considered

| Alternative | Why it lost |
|---|---|
| **Everything to GCP** (Identity Platform, Cloud Scheduler + Cloud Tasks, Vertex AI, SendGrid) | Weeks of work, forces a password reset for every user, and SES has no equivalent. The cost comparison only needs the core: frontend, API, database. |
| **GKE Autopilot instead of Cloud Run** | A cluster fee and a control plane to understand, for one stateless container. |
| **Compute Engine e2-micro (free tier) with Postgres on the VM** | $0, but we would run, patch and back up Postgres ourselves, and nothing scales to zero. |
| **Add `gcp/` to the `infra/` root module** | One state for two clouds: a broken GCP credential blocks every AWS plan, and `terraform destroy` for the lab cleanup would also aim at Cognito. |
| **A JSON key for the Terraform SA** | Exactly the long-lived secret ADR 0007 removed on AWS. ADC + impersonation on the laptop, WIF in CI. |

## Consequences

- One image, two targets: `docker build --target lambda` (AWS, adds Lambda Web Adapter) and the
  default target (Docker Compose, Cloud Run), which listens on `$PORT`.
- Two roads again, as in ADR 0007: Terraform owns the Cloud Run service's shape, `gcp/deploy.sh`
  owns the image (`ignore_changes` on the image).
- The GCP deployment's idle bill is a choice someone has to make: ≈ $1.70 stopped or ≈ $9.40
  running, against ≈ $0.30 on AWS. Forgetting to stop the instance is the GCP version of Lab 4's
  "Aurora kept awake" trap (cost table: [`docs/lab9-report.md`](../lab9-report.md#part-3--cost)).
- Cognito's callback URLs and the parser's CORS origins need `https://<project>.web.app` added
  to `app_urls` in `infra/terraform.tfvars` (a pull request to the AWS workspace) before sign-in
  works on the GCP URL.
