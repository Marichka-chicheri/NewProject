# The pieces that have to exist before gcp/ can be applied by anyone but a project Owner:
#   - the APIs that IAM and Workload Identity Federation need,
#   - the service account Terraform runs as (no Owner/Editor, the roles from Lab 9 Part 0),
#   - the service account the API runs as (not the default compute SA), with Cloud SQL Client,
#   - a Workload Identity pool + OIDC provider for GitHub Actions, limited to this repository by
#     its numeric IDs, so CI gets short-lived tokens instead of a service account key.
#
# Applied once, from the laptop, by the project Owner with `gcloud auth application-default
# login`; the state stays local (*.tfstate is in .gitignore). Granting project-level roles needs
# Project IAM Admin, which the Terraform service account deliberately does not have, so this is
# also where the API's project-level role lives.
#
#   cd gcp/bootstrap
#   terraform init
#   terraform apply -var project_id=spry-<name>-2026 -var admin_email=<you>@gmail.com

terraform {
  required_version = ">= 1.10"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}

variable "project_id" {
  type        = string
  description = "The GCP project created by hand, e.g. spry-marichka-2026."
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "admin_email" {
  type        = string
  description = "Your Google account. It may impersonate the Terraform service account (Service Account Token Creator)."
}

# Numeric IDs, not names: a repository can be renamed or re-created under the same name by someone
# else, its ID cannot. curl -s https://api.github.com/repos/<owner>/<repo> | jq '.id, .owner.id'
variable "github_repository_id" {
  type    = string
  default = "1395636976" # Marichka-chicheri/NewProject
}

variable "github_owner_id" {
  type    = string
  default = "245593433" # Marichka-chicheri
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_project_service" "bootstrap" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# ------------------------------------------------------------------ Terraform's service account

resource "google_service_account" "terraform" {
  account_id   = "spry-terraform"
  display_name = "Terraform (gcp/)"
  description  = "Applies gcp/. No Owner/Editor; impersonated from the laptop, WIF from CI."

  depends_on = [google_project_service.bootstrap]
}

resource "google_project_iam_member" "terraform" {
  for_each = toset([
    "roles/run.admin",
    "roles/cloudsql.admin",
    "roles/artifactregistry.admin",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/iam.serviceAccountUser",
    # Not in the Lab 9 list: adding Firebase to the project and creating the Hosting site.
    "roles/firebase.admin",
  ])

  project = var.project_id
  role    = each.value
  member  = google_service_account.terraform.member
}

# The laptop runs Terraform as this service account (provider impersonate_service_account),
# with the owner's own short-lived ADC token. No key file is ever created.
resource "google_service_account_iam_member" "admin_impersonates_terraform" {
  service_account_id = google_service_account.terraform.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${var.admin_email}"
}

# ------------------------------------------------------------------- the API's service account

resource "google_service_account" "api" {
  account_id   = "spry-api"
  display_name = "Spry API (Cloud Run)"
  description  = "Identity of the Cloud Run backend. Cloud SQL Client here; secret access is granted per secret in gcp/."

  depends_on = [google_project_service.bootstrap]
}

# Cloud SQL has no per-instance IAM, so the connection permission is project-wide.
resource "google_project_iam_member" "api_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = google_service_account.api.member
}

# -------------------------------------------------- Workload Identity Federation (GitHub Actions)

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"

  depends_on = [google_project_service.bootstrap]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-actions"
  display_name                       = "token.actions.githubusercontent.com"

  attribute_mapping = {
    "google.subject"                = "assertion.sub"
    "attribute.repository_id"       = "assertion.repository_id"
    "attribute.repository_owner_id" = "assertion.repository_owner_id"
    "attribute.ref"                 = "assertion.ref"
  }

  # Without a condition, any GitHub repository in the world could exchange its token here.
  attribute_condition = "assertion.repository_owner_id == '${var.github_owner_id}' && assertion.repository_id == '${var.github_repository_id}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "github_impersonates_terraform" {
  service_account_id = google_service_account.terraform.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository_id/${var.github_repository_id}"
}

# ------------------------------------------------------------------------------------- outputs

output "terraform_service_account" {
  value       = google_service_account.terraform.email
  description = "terraform_service_account in gcp/terraform.tfvars."
}

output "api_service_account" {
  value = google_service_account.api.email
}

output "workload_identity_provider" {
  value       = google_iam_workload_identity_pool_provider.github.name
  description = "workload_identity_provider of google-github-actions/auth."
}
