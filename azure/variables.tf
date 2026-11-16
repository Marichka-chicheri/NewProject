variable "subscription_id" {
  type        = string
  description = "Azure subscription ID (az account show --query id -o tsv)."
}

variable "project_name" {
  type    = string
  default = "spry"
}

variable "location" {
  type        = string
  default     = "centralus"
  description = "Region of the database, registry and API. Azure for Students limits the regions a subscription may use (policy 'Allowed resource deployment regions'): pick one it lists."
}

variable "swa_location" {
  type        = string
  default     = "centralus"
  description = "Static Web Apps exist only in westus2, centralus, eastus2, westeurope and eastasia."
}

variable "db_sku" {
  type        = string
  default     = "B_Standard_B1ms"
  description = "Burstable 1 vCore / 2 GiB, the smallest PostgreSQL Flexible Server."
}

variable "db_storage_mb" {
  type        = number
  default     = 32768
  description = "32 GiB is the minimum Flexible Server storage."
}

variable "cognito_user_pool_id" {
  type        = string
  description = "infra/ output user_pool_id. The API validates Cognito ID tokens itself."
}

variable "cognito_client_id" {
  type = string
}

variable "extra_cors_origins" {
  type    = list(string)
  default = ["http://localhost:5173"]
}

# A placeholder until the first azure/deploy.sh; after that the script rolls out the real image
# (az containerapp update), Terraform ignores it (see ignore_changes in api.tf).
variable "initial_image" {
  type    = string
  default = "mcr.microsoft.com/k8se/quickstart:latest"
}
