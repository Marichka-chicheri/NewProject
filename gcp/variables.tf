variable "project_id" {
  type        = string
  description = "GCP project ID (permanent, globally unique), e.g. spry-marichka-2026."
}

variable "project_name" {
  type        = string
  default     = "spry"
  description = "Prefix of resource names and the value of the project_name label (Lab 4's tag rule)."
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "terraform_service_account" {
  type        = string
  default     = ""
  description = "Email of the Terraform SA from gcp/bootstrap. Empty: run as your own ADC identity."
}

variable "api_service_account" {
  type        = string
  description = "Email of the SA the API runs as (gcp/bootstrap output api_service_account)."
}

# ---------------------------------------------------------------------------------- database

variable "db_activation_policy" {
  type        = string
  default     = "ALWAYS"
  description = "ALWAYS runs the instance; NEVER stops it (no compute billed, storage still is). Cloud SQL never pauses on its own."

  validation {
    condition     = contains(["ALWAYS", "NEVER"], var.db_activation_policy)
    error_message = "ALWAYS or NEVER."
  }
}

variable "db_deletion_protection" {
  type        = bool
  default     = false
  description = "Off for the lab, so `terraform destroy` removes the instance. Turn on for real data."
}

# ------------------------------------------------------- sign-in stays on AWS (Cognito, infra/)

variable "cognito_user_pool_id" {
  type        = string
  description = "infra/ output user_pool_id. The API validates Cognito ID tokens itself."
}

variable "cognito_client_id" {
  type = string
}

variable "extra_cors_origins" {
  type        = list(string)
  default     = ["http://localhost:5173"]
  description = "Origins besides the Firebase Hosting ones that may call the Cloud Run URL directly."
}

# A placeholder until the first `gcp/deploy.sh`. After that the image is deployed by the script
# (gcloud run services update), not by Terraform: see ignore_changes in run.tf.
variable "initial_image" {
  type    = string
  default = "us-docker.pkg.dev/cloudrun/container/hello"
}
