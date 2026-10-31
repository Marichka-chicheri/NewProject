# 7. Describe Cognito, the reports and the agenda parser in Terraform, applied by HCP Terraform

- Status: accepted
- Date: 2026-10-31
- Lab: 7 (Terraform)

## Context

Labs 4–6 gave us three CloudFormation templates (Cognito, the weekly report, the agenda parser).
They work, but they answer only half of the question "who creates the infrastructure, and where is
it written down?":

- **Who runs them.** `make deploy-auth`, `make deploy-reports` and `make deploy-ai` run on one
  laptop, with an IAM user's long-lived access key in `.env`. The key can do anything the scripts
  can; the pipeline has a copy of it (`AWS_ACCESS_KEY_ID` in GitHub secrets).
- **What the scripts hide.** Part of the real description lives in bash, not in the template: the
  reports script looks up the VPC, the subnets and the database password and passes them as
  parameters; the frontend script rewrites Cognito's redirect URLs. A reader of `auth.yaml` does
  not see what actually runs.
- **No review of the change.** CloudFormation has change sets, but the scripts apply them
  immediately. Nothing shows a teammate "+3 to add, 1 to destroy" before it happens.
- **One environment, one provider.** We will need a second environment (stage) and some of our
  infrastructure is already outside AWS (the Google OAuth client, GitHub). CloudFormation stops at
  the edge of one AWS account.
- **The cost of getting it wrong is high.** The user pool holds every account that signed up, and
  the reports bucket holds every report. Neither can be re-created.

## Decision

- **Terraform**, one root module in `infra/` (`auth.tf`, `reports.tf`, `ai.tf`, `variables.tf`,
  `outputs.tf`), AWS provider `~> 6.0`. The backend, the database and the frontend stay on
  CloudFormation; Terraform reads the backend stack's outputs (`aws_cloudformation_stack` data
  source), the database password (SSM) and the backend's image (`aws_lambda_function` data
  source). Moving the rest is a later, separate decision.
- **The existing resources were adopted, not re-created.** The three stacks were deleted with
  `DeletionPolicy: Retain` on every resource, so nothing in AWS was touched, and `import` blocks
  handed 20 resources to Terraform (steps and the list of what was re-created instead:
  `docs/lab7-migration.md`). The user pool and the reports bucket have
  `lifecycle { prevent_destroy = true }`: a plan that wants to replace them is an error, not a
  question.
- **State and runs are in HCP Terraform**, workspace `new-project-dev`, connected to this
  repository (working directory `infra`), execution mode *Remote*. A pull request gets a
  speculative plan as a check; a merge to `main` plans and, after a person confirms, applies.
- **No AWS keys for Terraform.** The workspace assumes the IAM role `hcp-terraform-<org>` with
  dynamic credentials (OIDC: `TFC_AWS_PROVIDER_AUTH`, `TFC_AWS_RUN_ROLE_ARN`). The role's trust
  policy accepts one organization and one workspace. The role and the OIDC provider are the only
  thing applied from a laptop, once (`infra/bootstrap/`, local state).
- **Two roads, not one.** GitHub Actions deploys the application (backend image, frontend, and
  `infra/update-lambdas.sh`, which moves the report builder and the agenda parser to the new
  image); HCP Terraform deploys the infrastructure. The image of those two functions is
  `ignore_changes` in Terraform, so a code deploy never shows up as drift and a Terraform run
  never rolls the code back. When a change needs both (a new environment variable), the Terraform
  pull request is merged first and the code must tolerate the variable being absent for a few
  minutes.
- **The Makefile never applies.** `make infra-init|fmt|validate|plan|output` only read or plan.
  `terraform apply` exists only in HCP Terraform.
- **What changed on the way (on purpose).** The IAM roles had names CloudFormation generated
  (`new-project-reports-ReportBuilderRole-1A2B3C…`); Terraform creates roles with stable names
  (`new-project-report-builder`) and the old roles were deleted afterwards. Lambda permissions got
  new statement ids. Cognito's redirect URLs and the parser's CORS origins are now the `app_urls`
  variable in `infra/terraform.tfvars` (a pull request) instead of being rewritten by the
  frontend deploy script.

## Alternatives considered

| Alternative | Why it lost |
|---|---|
| **Keep CloudFormation** | Works, free, AWS keeps the state and rolls back failed changes. But AWS-only, no plan in front of a reviewer in our workflow, and the scripts around it are where the real logic hides. Right choice if the whole world stayed one AWS account and nobody needed a second environment. |
| **AWS CDK** | A real programming language that compiles to CloudFormation, so same state model, same rollback, same AWS-only limit. It would make `auth.yaml` shorter, not make the infrastructure reviewable as a plan, and would add Node build steps to a course that is already Python + TypeScript. |
| **OpenTofu** | Same files, same commands, open-source licence (the Terraform CLI is BSL since 2023). HCP Terraform's runs, OIDC integration and VCS-connected workspaces are what this decision is about, and they are Terraform's. Switching later is cheap (`tofu` reads these files), so the licence is a risk we accept for now. |
| **Terraform with state in S3** | Free and under our control, but then we also build the locking, the run environment, the OIDC role for CI and the plan-on-pull-request check that HCP Terraform gives for free at our size. Rejected for now; the state is portable (`terraform state pull`). |
| **Delete the stacks and apply the Terraform** | Deletes every Cognito account and every report. Rejected as unacceptable for a pool that real users signed up in. |

## Consequences

- **Who can change the infrastructure now.** Anyone who can merge a pull request to `main`; the
  apply then waits for a person with write access to the workspace to confirm it (auto-apply is
  off). Requiring a review before merging is a GitHub branch-protection setting, to be turned on
  before a second person joins. Nobody
  needs AWS keys to change Cognito, the reports or the parser. The remaining long-lived key
  (`.env`, GitHub secrets) deploys the backend and the frontend and should be replaced by an OIDC
  role in the same way; it is not needed for anything in `infra/*.tf`.
- **Where the secrets end up.**
  - The Google client secret (not enabled today): a *sensitive* variable of the workspace
    (write-only in the UI), never in Git or `terraform.tfvars`. It is also in the state, because
    `aws_cognito_identity_provider.provider_details` contains it, and in Cognito. `sensitive = true`
    hides it in plans and logs, not in the state.
  - The database password is read from SSM by `data "aws_ssm_parameter"` to build `DATABASE_URL`
    for the report builder. That puts it **in the state** (and, as before, in the function's
    environment variables). Anyone who can read the workspace's state can read the database
    password, so state access is as sensitive as database access. The cleaner fix is to let the
    function read the parameter at start-up with its own role; not done here because it changes
    application code.
  - The AWS credentials of a run are temporary (the run's lifetime) and never stored.
  - The state is encrypted at rest by HCP Terraform and every version is kept. It must not be
    committed to Git (`.gitignore`) or copied around.
- **If HCP Terraform is down.** Everything that exists keeps running: Cognito, the API, the
  schedule, the parser and the pipeline that deploys the application do not depend on it. What stops
  is *changing* the infrastructure through the normal road. For a real emergency a person with AWS
  access fixes the resource in the console or CLI and then makes the code say the same thing in a
  pull request, so the next plan shows no drift (fixing it by hand and forgetting is how the
  problem in Part 0 starts). Exporting the state now and then (`terraform state pull`) keeps a
  copy for recovery. The risk we accept: for a while we cannot apply, and a second place (HCP) now
  has to be protected and paid attention to.
- **State is ours now.** CloudFormation kept it for us; Terraform needs it to know which resources
  are its own. Losing it makes the next plan want to create everything again (and fail on names).
  `prevent_destroy` on the pool and the bucket, HCP's state versions and the fact that a plan is
  always read before an apply are the safety net.
- **Cost.** HCP Terraform's free tier covers a project of this size; check the limit on managed
  resources before adding a second environment. No change in AWS cost.
- **Open points.** The role Terraform assumes is `AdministratorAccess` (class project): narrow it
  to the services in `infra/*.tf`. The backend, database and frontend are still CloudFormation and
  are the next candidates. `app_urls` must be updated by hand after the frontend gets a new
  address (the deploy script reminds you). A `stage` environment is now one more workspace and
  one more `.tfvars` file, but the names in `*.tf` (`${var.project_name}-…`) and the bucket
  and domain prefixes have to be checked for collisions first.
