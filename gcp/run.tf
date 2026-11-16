# The backend container on Cloud Run (was Lambda + function URL). Same image as Docker Compose,
# built with the default target (no Lambda Web Adapter); uvicorn listens on $PORT (8080 here).

locals {
  hosting_origins = [
    "https://${google_firebase_hosting_site.frontend.site_id}.web.app",
    "https://${google_firebase_hosting_site.frontend.site_id}.firebaseapp.com",
  ]
  image_repository = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.backend.repository_id}"
}

resource "google_cloud_run_v2_service" "api" {
  name                = "${var.project_name}-api"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = var.api_service_account

    # Scale to zero like Lambda: no requests, no instances, no bill. The first request after a
    # quiet period waits for a cold start (container start + alembic check).
    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    # db-f1-micro allows ~25 connections: 2 instances x (5 + 2 overflow) leaves room for psql.
    max_instance_request_concurrency = 40
    timeout                          = "60s"

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.db.connection_name]
      }
    }

    containers {
      image = var.initial_image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        # Request-based billing: CPU only while a request is being handled.
        cpu_idle          = true
        startup_cpu_boost = true
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      # app/config.py builds DATABASE_URL from these: the Unix socket /cloudsql/<connection name>.
      env {
        name  = "CLOUD_SQL_INSTANCE"
        value = google_sql_database_instance.db.connection_name
      }
      env {
        name  = "DB_NAME"
        value = google_sql_database.app.name
      }
      env {
        name  = "DB_USER"
        value = google_sql_user.app.name
      }
      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_password.secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "DB_POOL_SIZE"
        value = "5"
      }
      env {
        name  = "DB_MAX_OVERFLOW"
        value = "2"
      }
      env {
        name  = "COGNITO_USER_POOL_ID"
        value = var.cognito_user_pool_id
      }
      env {
        name  = "COGNITO_CLIENT_ID"
        value = var.cognito_client_id
      }
      env {
        name  = "CORS_ORIGINS"
        value = join(",", concat(local.hosting_origins, var.extra_cors_origins))
      }

      # Migrations run before uvicorn starts listening; give them up to ~2.5 minutes.
      startup_probe {
        tcp_socket {
          port = 8080
        }
        period_seconds    = 5
        timeout_seconds   = 3
        failure_threshold = 30
      }
    }
  }

  # Two roads, as on AWS (ADR 0007): Terraform owns the service's shape, gcp/deploy.sh owns the
  # code. A code deploy does not show up as drift and a Terraform run never rolls the code back.
  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  depends_on = [
    google_project_service.apis,
    google_secret_manager_secret_iam_member.api_reads_db_password,
    google_secret_manager_secret_version.db_password,
  ]
}

# Public: the API checks Cognito ID tokens itself (app/auth.py); only /api/health is anonymous.
# Firebase Hosting's /api/** rewrite also needs the service to be publicly invokable.
resource "google_cloud_run_v2_service_iam_member" "public" {
  name     = google_cloud_run_v2_service.api.name
  location = google_cloud_run_v2_service.api.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}
