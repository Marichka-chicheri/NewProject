# Lab 7: moving Cognito, the reports and the agenda parser from CloudFormation to Terraform

The decision and its reasons are in [ADR 0007](adr/0007-terraform.md). This is the runbook: what
was done, in which order, and what to look at. Commands are for Git Bash from the project root,
with the AWS CLI **outside** the Python venv (`deactivate` first).

**The rule of the whole migration:** the user pool (every account) and the reports bucket (every
report) are never deleted and never replaced. CloudFormation lets go of them, Terraform takes
them over, and a plan that wants to replace either is not applied.

## What is in the repository

| File | Purpose |
|---|---|
| `infra/versions.tf`, `variables.tf`, `outputs.tf`, `terraform.tfvars` | Providers, the HCP Terraform workspace, inputs (non-secret values only) and outputs |
| `infra/auth.tf`, `reports.tf`, `ai.tf` | Were `auth.yaml`, `reports.yaml`, `ai.yml` |
| `infra/lambda/report_mailer.py` | The mailer's code, which used to be inline in `reports.yaml` |
| `infra/bootstrap/` | OIDC provider and IAM role for HCP Terraform (applied once, local state) |
| `infra/migrate/` | Helpers for the migration; removed at the end |
| `infra/update-lambdas.sh` | Moves the report builder and the parser to the backend's current image |

## Step 0: tools and accounts

1. Terraform 1.10+ (`terraform version`). `terraform login` stores an API token for app.terraform.io.
2. An HCP Terraform organization. The files assume `ooad-marichka-chicheri`: if yours has another
   name, change `organization` in `infra/versions.tf` and use it below.
3. `aws sts get-caller-identity` shows the account you expect.

## Step 1: let HCP Terraform reach AWS (once)

```bash
cd infra/bootstrap
terraform init
terraform apply -var tfc_organization=ooad-marichka-chicheri   # read the plan: OIDC provider, role, policy
```

Copy the `role_arn` output. If you already did this in the in-class walkthrough, reuse that role and
only add the workspace `new-project-dev` to its trust policy (and skip the apply).

In HCP Terraform create the workspace **`new-project-dev`** (CLI-driven for now, execution mode
**Remote**) and add two *environment* variables: `TFC_AWS_PROVIDER_AUTH=true` and
`TFC_AWS_RUN_ROLE_ARN=<role_arn>`. If Google sign-in is enabled (see Step 2), also add the
*Terraform* variable `google_client_secret` (sensitive).

## Step 2: look before you touch

```bash
aws cognito-idp list-identity-providers --user-pool-id "$COGNITO_USER_POOL_ID"   # is Google there?
aws cloudformation list-stack-resources --stack-name new-project-auth --query 'StackResourceSummaries[].[LogicalResourceId,ResourceType,PhysicalResourceId]' --output table
```

If Google is a provider, put its client id into `google_client_id` in `infra/terraform.tfvars` and
keep the secret in the workspace. Otherwise leave it empty.

Cognito's redirect URLs and the parser's CORS origins become the `app_urls` list in
`infra/terraform.tfvars`. Make it match what is deployed today, or the plan will remove an address
and sign-in through it will stop:

```bash
aws cloudformation describe-stacks --stack-name new-project-frontend \
  --query "Stacks[0].Outputs[?OutputKey=='AppUrl' || OutputKey=='CustomDomainUrl'].OutputValue" --output text
aws cognito-idp describe-user-pool-client --user-pool-id "$COGNITO_USER_POOL_ID" \
  --client-id "$COGNITO_CLIENT_ID" --query UserPoolClient.CallbackURLs
```

Every origin in those callback URLs (the part before `/login`) belongs in `app_urls`, including the
CloudFront address (`https://dxxxx.cloudfront.net`).

## Step 3: CloudFormation lets go (Retain), nothing is deleted

```bash
bash infra/migrate/retain.sh
```

Adds `DeletionPolicy` and `UpdateReplacePolicy: Retain` to every resource of the three templates
except Lambda permissions, redeploys the stacks with their previous parameters, then reads the
stored template back from CloudFormation and checks every resource is marked. If CloudFormation
treated the change as "nothing to update", the check fails and `MIGRATION_TAG=1 bash
infra/migrate/retain.sh` forces an update with a stack tag.

## Step 4: write down the real IDs

```bash
bash infra/migrate/imports.sh
```

Creates `infra/imports.tf` (20 `import` blocks, or 21 with Google) and `infra/migrate/old-roles.txt`.
Open `imports.tf` and read it: each `id` is the ID in the provider's import documentation.

## Step 5: delete the three stacks

```bash
for s in new-project-ai new-project-reports new-project-auth; do
  aws cloudformation delete-stack --stack-name "$s"
  aws cloudformation wait stack-delete-complete --stack-name "$s"
done
```

Check in the console before going on: the user pool, the reports bucket, the Lambda functions, the
queues and the log groups are all still there, now with no stack. The Lambda permissions are not
retained: S3 → mailer and the parser's function URL stop working until the apply in Step 7 (a few
minutes).

## Step 6: plan until it only says what you expect

```bash
make infra-init
make infra-validate
make infra-plan
```

A speculative plan runs in HCP Terraform with the OIDC role. The expected result:

```
Plan: 20 to import, 14 to add, 3 to change, 0 to destroy.
```

- **20 to import:** the resources that exist and are adopted as they are.
- **14 to add:** four IAM roles with stable names (`new-project-report-scheduler`,
  `-report-builder`, `-report-mailer`, `-agenda-parser`), their four inline policies, three managed
  policy attachments and three Lambda permissions. Nothing user-visible is created.
- **3 to change:** the three Lambda functions (new role; the mailer also gets its code from the
  repository instead of the inline `ZipFile`; same code).
- **0 to destroy.** Anything else is a mismatch between the HCL and the real resource: fix the HCL,
  not the resource, until it goes away. A `-/+` with `# forces replacement` on the user pool or the
  bucket is never applied (and `prevent_destroy` makes the run fail rather than do it).

Where a mismatch is likely: the user pool's `schema` blocks (copy what the plan says the pool has),
`aws_budgets_budget` (`cost_types`, `limit_amount`), `aws_lambda_event_source_mapping` and the SQS
queues' encryption setting. For a first draft of any resource: `terraform plan
-generate-config-out=generated.tf` and compare it with yours.

## Step 7: apply through the pipeline, not from the laptop

1. Create a branch, commit everything (the Terraform files, `imports.tf`, **`infra/.terraform.lock.hcl`**,
   the Makefile, README and ADR changes; the old templates are still in), push, open a pull
   request. If the run's `terraform init` complains about provider checksums, generate the lock
   file for the runner's platform too: `terraform -chdir=infra providers lock -platform=linux_amd64
   -platform=windows_amd64`.
2. In the workspace: *Settings → Version Control* → connect this repository, **working directory
   `infra`**, trigger on changes under `infra/`. The pull request now gets a speculative plan as a
   check; read it again.
3. Merge. The workspace starts a run from the merge; confirm the apply in HCP Terraform.
   **That run, ending in *Apply finished*, is the screenshot for submission item 2.**
4. Check the application: sign in, create a meeting, paste an agenda, `make report-now`.

## Step 8: plan again, then clean up

```bash
make infra-plan     # must end with: No changes. Your infrastructure matches the configuration.
```

Save that output (submission item 3). Then:

```bash
bash infra/migrate/finish.sh   # deletes the 4 old IAM roles, git rm's the old templates, scripts and imports.tf
git rm -rf infra/migrate
```

Commit, open a second pull request, merge, and run `make infra-plan` once more: still *No
changes*. (This run changes nothing in AWS, so HCP Terraform ends it with *Planned and finished*,
not *Apply finished*; that is why the screenshot comes from Step 7.)

## What Terraform imported and what it re-created

| Resources | How | Why it is safe |
|---|---|---|
| User pool, domain, app client, managed-login branding | imported | The accounts never move |
| Reports bucket, its lifecycle rule and its notification | imported | The reports never move; the notification and the rule were part of the bucket resource in CloudFormation |
| VPC endpoint, two queues, schedule, three log groups, two functions, event source mapping, the parser's function and URL, the budget | imported | Same resource, new owner |
| Four IAM roles, their policies and attachments | **re-created** with stable names | CloudFormation had generated their names, and a name that differs would force a replacement. The three Lambda functions switch to the new roles in the same apply; the old roles are deleted afterwards |
| Three Lambda permissions | **re-created** | Child resources with generated statement ids, nothing depends on the old ids. The gap between Step 5 and Step 7 is the only downtime |

## Drift (Step 5 of the lab)

Change the parser's timeout by hand in the console, then *New run → Plan only*. The plan shows
`timeout: <your value> -> 30` and wants to put it back. If that change had been a real 23:00 fix, putting it
back would undo the fix; the team should have made the same change in `infra/ai.tf` in a pull
request (a hotfix branch, a plan, a merge): the fix lives in the code, and the apply is only the
paperwork.
