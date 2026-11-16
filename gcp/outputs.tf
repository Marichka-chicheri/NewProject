output "app_url" {
  value       = local.hosting_origins[0]
  description = "The frontend. /api/** is rewritten to Cloud Run, so the browser stays on one origin."
}

output "api_url" {
  value = google_cloud_run_v2_service.api.uri
}

output "api_service" {
  value = google_cloud_run_v2_service.api.name
}

output "image_repository" {
  value       = local.image_repository
  description = "Push backend images here (gcp/deploy.sh)."
}

output "db_instance" {
  value = google_sql_database_instance.db.name
}

output "db_connection_name" {
  value = google_sql_database_instance.db.connection_name
}

output "db_password_secret" {
  value = google_secret_manager_secret.db_password.secret_id
}
