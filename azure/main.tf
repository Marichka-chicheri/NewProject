resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project_name}"
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------- Container Registry
# The only always-on fixed cost besides the database: Basic is ~$5/month (no free tier).

resource "azurerm_container_registry" "main" {
  name                = "${var.project_name}${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = false # no shared registry password: the API pulls with its managed identity
  tags                = local.tags
}

# -------------------------------------------------------------------------------------- Logs
# Container Apps send stdout here (was CloudWatch / Cloud Logging). 5 GB/month are free.

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${var.project_name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

# ---------------------------------------------------------------------- Identity of the API
# Its own managed identity (the Azure service account): AcrPull on the registry, Secrets User on
# one Key Vault. No credentials exist: Azure issues it tokens.

resource "azurerm_user_assigned_identity" "api" {
  name                = "id-${var.project_name}-api"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "api_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.api.principal_id
}

# ------------------------------------------------------------------------------- Key Vault

resource "azurerm_key_vault" "main" {
  name                       = "kv-${var.project_name}-${local.suffix}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  tags                       = local.tags
}

# Whoever runs Terraform may write the secret; the API may only read it.
resource "azurerm_role_assignment" "deployer_kv_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "api_kv_reader" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.api.principal_id
}

# ---------------------------------------------------------------------- Static Web Apps (frontend)
# Free plan: global CDN, TLS, SPA fallback (frontend/public/staticwebapp.config.json). The free
# plan cannot proxy /api/** to a Container App (that "linked backend" is Standard, ~$9/month), so
# the bundle is built with VITE_API_URL = the Container App's URL and the API allows its origin.

resource "azurerm_static_web_app" "frontend" {
  name                = "swa-${var.project_name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.swa_location
  sku_tier            = "Free"
  sku_size            = "Free"
  tags                = local.tags
}
