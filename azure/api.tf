# The backend container on Azure Container Apps (was Lambda / Cloud Run). The same image as Docker
# Compose, built with the default Docker target (no Lambda Web Adapter): uvicorn listens on $PORT.

resource "azurerm_container_app_environment" "main" {
  name                       = "cae-${var.project_name}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  tags                       = local.tags
}

resource "azurerm_container_app" "api" {
  name                         = "${var.project_name}-api"
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.api.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.api.id
  }

  # The password is read from Key Vault by the API's identity; it is not in the app's definition.
  secret {
    name                = "db-password"
    key_vault_secret_id = azurerm_key_vault_secret.db_password.versionless_id
    identity            = azurerm_user_assigned_identity.api.id
  }

  template {
    # Scale to zero like Lambda: no requests, no replica, no bill (the free grant covers the rest).
    min_replicas = 0
    max_replicas = 2

    container {
      name   = "api"
      image  = var.initial_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "PORT"
        value = "8080"
      }
      # app/config.py builds DATABASE_URL (TLS required) from these.
      env {
        name  = "DB_HOST"
        value = azurerm_postgresql_flexible_server.db.fqdn
      }
      env {
        name  = "DB_NAME"
        value = azurerm_postgresql_flexible_server_database.app.name
      }
      env {
        name  = "DB_USER"
        value = azurerm_postgresql_flexible_server.db.administrator_login
      }
      env {
        name        = "DB_PASSWORD"
        secret_name = "db-password"
      }
      # B1ms allows ~50 connections: 2 replicas x (5 + 2) leaves plenty.
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
        value = join(",", concat(["https://${azurerm_static_web_app.frontend.default_host_name}"], var.extra_cors_origins))
      }
    }
  }

  # Public: the API checks Cognito ID tokens itself (app/auth.py); only /api/health is anonymous.
  ingress {
    external_enabled = true
    target_port      = 8080
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  # Two roads (ADR 0007): Terraform owns the app's shape, azure/deploy.sh owns the image.
  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }

  depends_on = [
    azurerm_role_assignment.api_acr_pull,
    azurerm_role_assignment.api_kv_reader,
    azurerm_postgresql_flexible_server_firewall_rule.azure_services,
  ]
}
