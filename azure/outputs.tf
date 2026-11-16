output "app_url" {
  value = "https://${azurerm_static_web_app.frontend.default_host_name}"
}

output "api_url" {
  value = "https://${azurerm_container_app.api.ingress[0].fqdn}"
}

output "api_app" {
  value = azurerm_container_app.api.name
}

output "resource_group" {
  value = azurerm_resource_group.main.name
}

output "registry" {
  value = azurerm_container_registry.main.name
}

output "registry_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "static_web_app" {
  value = azurerm_static_web_app.frontend.name
}

output "db_server" {
  value = azurerm_postgresql_flexible_server.db.name
}
