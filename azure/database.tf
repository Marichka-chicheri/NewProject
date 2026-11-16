# Azure Database for PostgreSQL Flexible Server, Burstable B1ms. Like Cloud SQL (and unlike
# Aurora Serverless v2) it never pauses by itself: compute bills per hour while it is running.
# `az postgres flexible-server stop` stops compute billing (storage is still billed) but Azure
# starts the server again after 7 days. `terraform destroy` removes it.

resource "random_password" "db" {
  length  = 48
  special = false
  upper   = false
}

resource "azurerm_postgresql_flexible_server" "db" {
  name                = "${var.project_name}-db-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  version             = "17"
  sku_name            = var.db_sku
  storage_mb          = var.db_storage_mb
  storage_tier        = "P4"

  administrator_login    = "meetings"
  administrator_password = random_password.db.result

  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false
  public_network_access_enabled = true
  zone                          = "1"
  tags                          = local.tags

  lifecycle {
    # Azure picks the zone/standby zone on create and reports them back.
    ignore_changes = [zone, high_availability]
  }
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = "meetings"
  server_id = azurerm_postgresql_flexible_server.db.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# 0.0.0.0 - 0.0.0.0 is Azure's "allow Azure services" rule: any Azure customer's service could
# reach the server's public endpoint, so it is protected only by TLS and the password. The
# stricter options (private endpoint, VNet integration with a delegated subnet) add a VNet and
# ~$7/month or more; see ADR 0009.
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.db.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_key_vault_secret" "db_password" {
  name         = "db-password"
  value        = random_password.db.result
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_role_assignment.deployer_kv_officer]
}
