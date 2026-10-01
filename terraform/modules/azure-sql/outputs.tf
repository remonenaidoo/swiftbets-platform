output "server_fqdn" {
  description = "Fully qualified server name for connection strings."
  value       = azurerm_mssql_server.this.fully_qualified_domain_name
}

output "admin_login" {
  value = var.admin_login
}

output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}

output "databases" {
  value = [for db in azurerm_mssql_database.betstore : db.name]
}
