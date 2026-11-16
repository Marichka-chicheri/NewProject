# Cloud SQL for PostgreSQL, the smallest shared-core machine. Unlike Aurora Serverless v2 (0 ACU)
# it never pauses: it bills ~$0.0105/h while ALWAYS, and storage (10 GB SSD, ~$1.70/month) even
# while stopped. var.db_activation_policy = "NEVER" stops it; `terraform destroy` deletes it.

resource "google_sql_database_instance" "db" {
  name             = "${var.project_name}-db"
  database_version = "POSTGRES_17"
  region           = var.region

  deletion_protection = var.db_deletion_protection

  settings {
    # db-f1-micro exists only in the Enterprise edition; PostgreSQL 16+ defaults to Enterprise Plus.
    edition           = "ENTERPRISE"
    tier              = "db-f1-micro"
    availability_type = "ZONAL"
    activation_policy = var.db_activation_policy

    disk_type       = "PD_SSD"
    disk_size       = 10
    disk_autoresize = false

    deletion_protection_enabled = var.db_deletion_protection

    # Backups are billed per GB; this lab database holds nothing that cannot be re-created.
    backup_configuration {
      enabled = false
    }

    # A public IP with no authorized networks: nothing can connect over it directly. Cloud Run
    # reaches the instance through the Cloud SQL connector (IAM-checked, TLS), which needs no VPC
    # connector and no private services access, both of which cost money or setup.
    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"
    }

    user_labels = local.labels
  }

  depends_on = [google_project_service.apis]
}

resource "google_sql_database" "app" {
  name     = "meetings"
  instance = google_sql_database_instance.db.name
}

# Hex characters only: the password is safe in a URL and in a shell, and still 192 bits.
resource "random_password" "db" {
  length  = 48
  special = false
  upper   = false
}

resource "google_sql_user" "app" {
  name     = "meetings"
  instance = google_sql_database_instance.db.name
  password = random_password.db.result
}

# ----------------------------------------------------------------------------- Secret Manager

resource "google_secret_manager_secret" "db_password" {
  secret_id = "${var.project_name}-db-password"

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

# The value is also in the Terraform state (random_password), which HCP Terraform encrypts at rest.
# Nobody needs to read it: Cloud Run gets it from Secret Manager, people use `gcloud sql connect`.
resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result
}

# Only the API's service account may read this one secret.
resource "google_secret_manager_secret_iam_member" "api_reads_db_password" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.api_service_account}"
}
