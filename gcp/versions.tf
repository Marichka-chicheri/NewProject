terraform {
  required_version = ">= 1.10"

  # A second HCP Terraform workspace, separate from infra/ (new-project-dev): its own state, so a
  # mistake here can never plan a change to Cognito or the reports bucket, and `terraform destroy`
  # here removes only GCP. Execution mode Local: HCP Terraform keeps the state and the lock, the
  # plan and apply run on the laptop with gcloud ADC (impersonating the Terraform SA).
  cloud {
    organization = "ooad-marichka-chicheri"

    workspaces {
      name = "new-project-gcp"
    }
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

locals {
  impersonate = var.terraform_service_account == "" ? null : var.terraform_service_account
  labels      = { project_name = var.project_name }
}

provider "google" {
  project                     = var.project_id
  region                      = var.region
  impersonate_service_account = local.impersonate
  default_labels              = local.labels
}

# Firebase resources are beta-only. Firebase APIs need a quota project when called with user (or
# impersonated) credentials, hence user_project_override.
provider "google-beta" {
  project                     = var.project_id
  region                      = var.region
  impersonate_service_account = local.impersonate
  user_project_override       = true
  billing_project             = var.project_id
  default_labels              = local.labels
}
