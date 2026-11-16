# APIs this configuration uses. Enabled here, not by clicking in the console, so a new project is
# one `terraform apply` away. disable_on_destroy = false: `terraform destroy` removes the
# resources but leaves the APIs on (turning an API off can break things outside this state).
resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "sqladmin.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "firebase.googleapis.com",
    "firebasehosting.googleapis.com",
    "logging.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# --------------------------------------------------------------------------- Artifact Registry

resource "google_artifact_registry_repository" "backend" {
  repository_id = var.project_name
  location      = var.region
  format        = "DOCKER"
  description   = "Backend images (was ECR)."

  # 0.5 GB is free; one backend image is ~150 MB compressed. Keep the three most recent versions.
  cleanup_policy_dry_run = false
  cleanup_policies {
    id     = "keep-3-most-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 3
    }
  }
  cleanup_policies {
    id     = "delete-the-rest"
    action = "DELETE"
    condition {
      tag_state = "ANY"
    }
  }

  depends_on = [google_project_service.apis]
}

# ------------------------------------------------------------------------- Firebase Hosting

resource "google_firebase_project" "default" {
  provider = google-beta
  project  = var.project_id

  depends_on = [google_project_service.apis]
}

# The default site, <project_id>.web.app. Content and the /api/** rewrite are deployed by
# gcp/deploy.sh with firebase-tools (frontend/firebase.json): Terraform has no file upload.
resource "google_firebase_hosting_site" "frontend" {
  provider = google-beta
  project  = google_firebase_project.default.project
  site_id  = var.project_id
}
