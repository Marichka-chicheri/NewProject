# Lab 9 — Spry on a second cloud (Google Cloud design, no GCP account)

**Route taken: no Google Cloud account.** Google would not start the Free Trial for my payment
method without a $30 prepayment, so I submit the "no GCP account" variant of the lab: the `gcp/`
Terraform and ADR with `terraform init` / `validate` output, the Cloud Run image running locally
next to PostgreSQL, the cost table, and the Part 4 demos without billing (Colab notebook and
Looker Studio).

Sign-in, the weekly report and the agenda parser stay on AWS in the design. How the GCP
configuration would be deployed, stopped and destroyed: [README → Deploy to Google Cloud](../README.md#deploy-to-google-cloud-lab-9-not-applied).

## Submission

| Required item (no-account route) | Where |
|---|---|
| `gcp/` Terraform + ADR | [commit 28df7b1](https://github.com/Marichka-chicheri/NewProject/commit/28df7b1) — [`gcp/`](../gcp), [`docs/adr/0008-gcp-port.md`](adr/0008-gcp-port.md) |
| `terraform init` + `terraform validate` output (no Google credentials) | [`docs/lab9/terraform-validate.txt`](lab9/terraform-validate.txt): both succeed for `gcp/` and `gcp/bootstrap/` |
| The app as Cloud Run would run it, locally | [`docs/lab9/local-cloudrun-run.txt`](lab9/local-cloudrun-run.txt) (log, `curl /api/health`, tables) and the screenshot [`docs/lab9/frontend-local.png`](lab9/frontend-local.png) |
| Part 3 cost table | [below](#part-3--cost) |
| Part 4 demos without billing | [Colab notebook copy](https://colab.research.google.com/drive/1i2_7bhfAlwZmi_PCtzRCW1vttD1IPgwX?usp=sharing) and [Looker Studio dashboard](https://datastudio.google.com/reporting/3ba08407-7ad0-4c3f-a45d-4b6a051fedb8) |
| Three sentences (Markdown vs image, timings, when to pay for Document AI) | [Part 4](#part-4--ai-services-and-the-data-stack) (written) |

### Local run, as Cloud Run runs it

```bash
docker network create spry-lab9
docker run -d --name spry-pg --network spry-lab9 -e POSTGRES_USER=meetings -e POSTGRES_PASSWORD=meetings -e POSTGRES_DB=meetings postgres:17
docker build --target app -t spry-backend:cloudrun backend
docker run -d --name spry-api-8080 --network spry-lab9 -e PORT=8080   -e DATABASE_URL=postgresql+asyncpg://meetings:meetings@spry-pg:5432/meetings   -p 8080:8080 spry-backend:cloudrun
cd frontend && VITE_API_PROXY=http://localhost:8080 npm run dev     # http://localhost:5173
```

The image (default target, no Lambda Web Adapter: `/opt/extensions` does not exist) listens on
`$PORT`, runs the Alembic migrations on start and answers `GET /api/health` with `{"status":"ok"}`
after a `SELECT 1` on PostgreSQL. Through the Vite proxy the browser reaches the same API on one
origin, the way Firebase Hosting's `/api/**` rewrite would. The meetings page itself needs a
Cognito sign-in (sign-in stays on AWS), so the database-reading call shown is `/api/health`.

---

## Part 0 — Project and identity

- **Two service accounts, no keys.** `spry-terraform` applies `gcp/` with Cloud Run Admin, Cloud
  SQL Admin, Artifact Registry Administrator, Secret Manager Admin, Service Usage Admin, Service
  Account User, plus Firebase Admin (needed for Hosting) — no Owner, no Editor. `spry-api` is what
  Cloud Run runs as (Cloud SQL Client + access to one secret), not the default compute SA. Both are
  created by [`gcp/bootstrap/main.tf`](../gcp/bootstrap/main.tf).
- **Laptop:** `gcloud auth application-default login`; the provider impersonates `spry-terraform`
  (`impersonate_service_account`), allowed only for the owner's account (Token Creator).
- **CI:** Workload Identity pool `github`, OIDC provider for `token.actions.githubusercontent.com`,
  attribute condition on the numeric IDs `repository_owner_id == 245593433` and
  `repository_id == 1395636976`, Workload Identity User on `spry-terraform` for that repository's
  principal set. GitHub Actions would use `google-github-actions/auth` with
  `workload_identity_provider` + `service_account`; no secret is stored in GitHub.
- **APIs are enabled from Terraform** (`google_project_service`): IAM/STS/credentials in bootstrap;
  Cloud Run, Cloud SQL Admin, Secret Manager, Artifact Registry, Firebase, Firebase Hosting, Logging
  in `gcp/`.

## Part 1 — Mapping

The full table (16 rows, keep/replace/drop each) and the three answers — database, e-mail
provider and its key, features not moved — are in [ADR 0008](adr/0008-gcp-port.md). In short:

- **Database:** Cloud SQL PostgreSQL 17 `db-f1-micro`, stopped between demos. Firestore would
  bring the bill to $0 but is a rewrite; Aurora cross-cloud costs latency (~30 ms per round trip),
  egress and a hole in the VPC.
- **E-mail:** keep SES (the report stays on AWS; its Lambda role sends, no key). If the sender
  moves to GCP, it assumes an AWS role with its Google ID token; a Mailgun/SendGrid key would live
  only in Secret Manager.
- **Not moved:** Cognito (password hashes cannot be exported), the weekly report, the agenda
  parser, WAF, the custom domain.

## Part 2 — Moving the core

**GCP (written and validated, not applied):**

| Step | Done in |
|---|---|
| 1. `gcp/`, own state, google provider, APIs | [`gcp/versions.tf`](../gcp/versions.tf) (workspace `new-project-gcp`), [`gcp/main.tf`](../gcp/main.tf) |
| 2. Cloud SQL `db-f1-micro`, 10 GB SSD, us-central1, DB + user, password in Secret Manager | [`gcp/database.tf`](../gcp/database.tf) |
| 3. Image → Artifact Registry, no Lambda layer, Cloud Run as own SA, Cloud SQL + secret, min 0 | [`backend/Dockerfile`](../backend/Dockerfile), [`backend/app/config.py`](../backend/app/config.py), [`gcp/run.tf`](../gcp/run.tf), [`gcp/deploy.sh`](../gcp/deploy.sh) |
| 4. Frontend → Firebase Hosting, `/api/**` → Cloud Run | [`frontend/firebase.json`](../frontend/firebase.json), [`gcp/main.tf`](../gcp/main.tf) |
| 5. README | [Deploy to Google Cloud](../README.md#deploy-to-google-cloud-lab-9) |

Notes on the changes:

- **Lambda layer removed from the container path.** The Dockerfile has two targets. The default
  (`app`) is a plain container: `uvicorn --port ${PORT}` (8000 by default, 8080 on Cloud Run). The
  `lambda` target adds the Lambda Web Adapter extension and is built only by
  `infra/deploy-backend.sh` (`--target lambda`). The app never used Mangum.
- **Database URL.** Cloud Run mounts the Cloud SQL socket at `/cloudsql/<connection name>` and
  passes the Secret Manager password as `DB_PASSWORD`; `app/config.py` builds
  `postgresql+asyncpg://meetings:…@/meetings?host=/cloudsql/…` from `CLOUD_SQL_INSTANCE`,
  `DB_USER`, `DB_NAME`, `DB_PASSWORD`. Locally and on AWS nothing changes (`DATABASE_URL`).
- **Data: migrations, not pg_dump.** `alembic upgrade head` runs on container start, so Cloud SQL
  gets the schema from the same history. The Aurora data is test data in private subnets; see
  ADR 0008 for how a real copy would go.
- **Two roads.** Terraform creates Cloud Run with a placeholder image and ignores later image
  changes; `gcp/deploy.sh` pushes and rolls out the real one. Same split as ADR 0007 on AWS.
- **Cloud SQL edition trap avoided:** PostgreSQL 16+ defaults to the *Enterprise Plus* edition,
  which has no `db-f1-micro`; `edition = "ENTERPRISE"` is set explicitly.

## Part 3 — Cost

Region: GCP `us-central1`, AWS `us-east-1`, 730 h/month, list prices from the lab handout.
Traffic is small in every profile (a class app): even "busy" is ~1.3 M requests/month at
~100 ms, inside both free tiers.

### Line items (the app as built, database awake 730 h)

| Line | AWS | GCP |
|---|---|---|
| Frontend (CloudFront + S3 / Firebase Hosting) | $0 (free tier) | $0 (10 GB storage, 10 GB/month transfer free) |
| API (Lambda + function URL / Cloud Run) | $0 (1 M requests, 400k GB-s free) | $0 (2 M requests, 180k vCPU-s, 360k GiB-s free) |
| **DB compute** | Aurora Serverless v2, $0.12/ACU-h × 0.5 ACU awake; **$0 paused** | Cloud SQL `db-f1-micro` $0.0105/h → **$7.67**; $0 only when stopped |
| DB storage | ~1 GB × $0.10 = $0.10 | 10 GB SSD × $0.17 = $1.70 (**also while stopped**) |
| Registry | ECR ~3 images × 150 MB ≈ $0.05 | Artifact Registry 0.5 GB free, $0 |
| Secrets | SSM SecureString (standard) $0 | Secret Manager 6 versions, 10k accesses free, $0 |
| Logs | CloudWatch 5 GB free, $0 | Cloud Logging 50 GiB free, $0 |
| **Total, database never sleeps** | ≈ **$44** (0.5 ACU × 730 h) | ≈ **$9.40** |
| **Total, nobody uses it** | ≈ **$0.30** (Aurora paused) | ≈ **$9.40** running / **$1.70** stopped |

### Four profiles (from Lab 4)

Hours the database is awake per month: nobody 0 h; class demos 10 × 2 h = 20 h; office hours
8 h × 22 days = 176 h; busy 730 h. Aurora is assumed at its 0.5 ACU floor while awake (each
extra 0.5 ACU at peak doubles that line); "+ storage etc." is $0.10 + $0.20 on AWS, $1.70 on GCP.

| Profile | AWS (Aurora pauses by itself) | GCP, Cloud SQL left `ALWAYS` | GCP, Cloud SQL stopped outside use* | Cheaper |
|---|---|---|---|---|
| Nobody | 0 h → **$0.30** | $7.67 + $1.70 = **$9.37** | 0 h → **$1.70** | **AWS** |
| Class demos (10 × 2 h) | 20 × 0.5 × $0.12 = $1.20 → **$1.50** | **$9.37** | 20 × $0.0105 = $0.21 → **$1.91** | **AWS** (barely, and only if GCP is stopped) |
| Office hours (8 h × 22 d) | 176 × 0.5 × $0.12 = $10.56 → **$10.86** | **$9.37** | 176 × $0.0105 = $1.85 → **$3.55** | **GCP** |
| Busy 24/7 | 730 × 0.5 × $0.12 = $43.80 → **$44.10** | **$9.37** | — (never stopped) → **$9.37** | **GCP** (~4.7×) |

\* Stopping by hand (`db_activation_policy = "NEVER"`) or with two Cloud Scheduler jobs that patch
the activation policy at 08:00 and 16:00 (within the 3 free jobs). Cloud Run, Firebase Hosting,
Artifact Registry and Secret Manager are $0 in every profile; at "busy" Lambda adds ~$0.06 for
requests over 1 M.

_The table is computed from the handout's list prices; check it in the
[AWS](https://calculator.aws/) and [GCP](https://cloud.google.com/products/calculator) pricing
calculators and save the estimates' links/screenshots in `docs/lab9/`._

**Which cloud is cheaper per profile, and which single line decides it?**
AWS for *nobody* and *class demos*, GCP for *office hours* and *busy*. The deciding line every time
is **database compute**: everything else is free on both sides. Aurora Serverless v2 is priced per
ACU-hour and goes to $0 when paused, so it wins when the app is mostly asleep; but $0.12 for half
an ACU is ~5.7× the f1-micro's $0.0105, so once the database is awake for more than ~150 h/month, even an
always-on Cloud SQL is cheaper. Break-even with totals: $0.30 + $0.06 × h = $9.37 → h ≈ 151 h/month,
about 7 h every working day.

**Lab 4 showed Aurora can cost more than an instance when kept awake. Where is the equivalent
trap on GCP?**
The mirror image: on GCP nothing pauses unless you tell it to. A Cloud SQL instance left at
`ALWAYS` bills $7.67/month of compute for an app nobody opens, and stopping it still leaves the
storage bill, so "I'm not using it" is never $0 until the instance is **deleted**. The same trap
hides in three settings that look harmless:
- **Cloud SQL edition/tier:** PostgreSQL 16+ defaults to Enterprise Plus, whose smallest machine
  costs many times an f1-micro; `g1-small` is already $0.035/h ($25.55/month).
- **Cloud Run min instances ≥ 1 or "CPU always allocated"** (instance-based billing): the API stops
  scaling to zero and bills every second, the Cloud Run version of keeping Aurora awake.
- **Anything that keeps the database busy** (a health check that hits `/api/health` every minute,
  an uptime monitor) is harmless for Cloud SQL's bill but would keep Aurora awake 24/7 on AWS —
  so the "busy" profile can arrive without any users.

## Part 4 — AI services and the data stack

Without a Google Cloud account, the demos run without billing:

| Assignment demo | What I run instead |
|---|---|
| BigQuery query + bytes processed | SQL over a public dataset with DuckDB in the Colab notebook |
| Vision API OCR | Tesseract and EasyOCR in the notebook |
| Document AI | a scanned invoice → Markdown by an open vision-language model (Qwen3-VL 2B via Ollama) |
| Gemini prompt in Vertex AI Studio | my own prompt turning the invoice into JSON, run on the Markdown and on the image, checked against the right answer |
| Looker Studio chart | public dashboard over `owid-co2-data.csv` (needs only a Google account) |

Notebook copy: <https://colab.research.google.com/drive/1i2_7bhfAlwZmi_PCtzRCW1vttD1IPgwX?usp=sharing>. Dashboard: <https://datastudio.google.com/reporting/3ba08407-7ad0-4c3f-a45d-4b6a051fedb8>.

**One thing I noticed in the data:** Ukraine's CO₂ emissions peak at about 730 million tonnes around 1990 and fall to about 140 by the 2020s, while Switzerland and Ireland stay below 50 throughout.

**Three sentences.**

1. Neither input worked better: the Markdown (A) and the image (B) both matched 8 of 9 fields, and
   both missed the same one, `seller`, where the model wrote "Kozelnyska St" instead of
   "Kozelnytska St" — it dropped a letter of an unusual street name while copying it, so the limit
   was the small model's copying, not what it was given (the Markdown parse of the page was already
   correct enough for everything else).
2. Section 4 (the page to Markdown) took 32 s and each answer in section 5 took 3 s, on a Tesla T4
   GPU in Colab (the same result is expected on CPU, in about 5 min and 1.5–2 min).
3. I would pay for Document AI when the volume is high or the answer must be identical and
   checkable every time — thousands of invoices, tables that span pages, bounding boxes and
   confidence per field, an SLA — and keep the open model for a few documents with a good prompt
   (the model here misspelled a street name, which a trained invoice processor would not); I would
   also use the open model when documents are not allowed to leave my own machines.

The BigQuery version of the DuckDB query, for reference:

```sql
-- ~ 100–200 MB processed: only two columns of one table are read.
SELECT EXTRACT(HOUR FROM trip_start_timestamp) AS hour, COUNT(*) AS trips, ROUND(AVG(fare), 2) AS avg_fare
FROM `bigquery-public-data.chicago_taxi_trips.taxi_trips`
WHERE trip_start_timestamp >= '2023-01-01'
GROUP BY hour
ORDER BY hour;
```

(Columns read decide the bill, not `LIMIT`: `SELECT *` on the same table scans tens of GB.)

**Think: when is a specialised service like Document AI better than a general LLM, and when not?**
Document AI (or Vision OCR) is better when the input is a *document* and the output must be
*exact and checkable*: thousands of receipts, invoices or forms of a known kind, where each field
needs a bounding box and a confidence score, the result must be the same every time, and the
price must be predictable ($1.50 per 1,000 pages for OCR). It does not invent text that isn't on
the page, and a trained processor handles a fixed layout better than a prompt. A general LLM is
better when the input is *free text* with no fixed layout and the task needs understanding, not
reading — exactly the Lab 6 agenda parser: an e-mail or chat message where "after the break, Olia
on the budget, 15 min" has to become a structured item. It is also better for one-off or
low-volume jobs (no processor to train), and for questions over a document ("what is the due
date?"). The LLM loses on cost at volume, on determinism, and on audit (no coordinates, possible
hallucinated fields). A common combination: OCR first, LLM on the extracted text.

**Link to Lab 8: which parts of the Athena/Glue pipeline would be BigQuery, Dataflow and Looker
Studio, and what would we no longer manage?**

| Lab 8 on AWS | On GCP | What we would no longer manage |
|---|---|---|
| S3 raw CSV + Glue crawler + Glue Data Catalog table | Cloud Storage + a BigQuery external table, or load into native BigQuery storage | The crawler runs, its schema guesses and partition updates; the catalog is BigQuery's own |
| Glue job / CTAS CSV → Parquet, partitioning | Not needed: BigQuery stores columnar data itself; `PARTITION BY DATE(ts)` + clustering in the table definition. Dataflow (*Text to BigQuery* template) only for loading/cleaning | Choosing file formats, file sizes, Parquet compaction, partition folders |
| Athena queries ($5/TB scanned, per-query workgroups) | BigQuery queries ($6.25/TiB, 1 TiB/month free), same "pay for bytes read" model | Result buckets in S3, workgroup output locations |
| Kinesis Data Streams → Firehose → S3 (Part 4 streaming) | Pub/Sub → Dataflow (streaming) → BigQuery, or a Pub/Sub BigQuery subscription with no Dataflow at all | Shards and their capacity, Firehose buffering, the separate "stream lands in S3, then query" step |
| QuickSight / CSV results in `lab8/part2/results` | Looker Studio over BigQuery (free) | Exporting CSVs to look at a chart |

The big change is that the "lake" disappears as something we build: BigQuery is storage, catalog
and engine in one, so the crawler, the Parquet conversion and the partition folders of Lab 8 Part 2
are table settings, not jobs. What stays the same is the economics (pay per byte scanned, so
partitioning and selecting columns still matter) and the split between a batch road and a
streaming road.

## Part 5 — Certifications

Information only: Cloud Digital Leader (foundational), Associate Cloud Engineer (the closest match
to this lab: projects, IAM, Cloud Run, Cloud SQL, gcloud), then Professional Cloud Architect /
Data Engineer. The AWS counterparts are Cloud Practitioner → Solutions Architect Associate.

## Clean up

Nothing was created on Google Cloud, so there is nothing to bill. Locally:

- [ ] `docker rm -f spry-api-8080 spry-pg && docker network rm spry-lab9`, stop the Vite server.
- [ ] If the GCP configuration is ever applied: `cd gcp && terraform destroy` (a stopped Cloud SQL
      instance still bills its 10 GB SSD; a deleted one bills nothing), then
      `cd gcp/bootstrap && terraform destroy`, delete Dataflow output and BigQuery tables, and
      check Billing → Reports a day later.
