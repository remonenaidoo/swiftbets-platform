terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

resource "azurerm_resource_group" "this" {
  name     = "${var.name}-rg"
  location = var.location
}

resource "random_password" "admin" {
  length           = 32
  special          = true
  override_special = "-_.~"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
}

resource "azurerm_mssql_server" "this" {
  name                          = "${var.name}-sql-${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  version                       = "12.0"
  administrator_login           = var.admin_login
  administrator_login_password  = random_password.admin.result
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

# Only the OCI node's egress IP may connect; there is no "allow Azure services" rule.
resource "azurerm_mssql_firewall_rule" "oci" {
  name             = "oci-k3s-egress"
  server_id        = azurerm_mssql_server.this.id
  start_ip_address = var.allowed_ip
  end_ip_address   = var.allowed_ip
}

# One free-offer serverless database per owning service (the free offer covers up to ten per subscription).
resource "azurerm_mssql_database" "betstore" {
  for_each = toset(var.databases)

  name                        = each.value
  server_id                   = azurerm_mssql_server.this.id
  sku_name                    = "GP_S_Gen5_2"
  min_capacity                = 0.5
  auto_pause_delay_in_minutes = 60
  max_size_gb                 = 32
  zone_redundant              = false
  storage_account_type        = "Local"
}

# azurerm has no argument for the free offer; the ARM API does. Exhausting the monthly free allowance pauses the
# database until the next month instead of billing.
resource "azapi_update_resource" "free_offer" {
  for_each = azurerm_mssql_database.betstore

  type        = "Microsoft.Sql/servers/databases@2023-08-01-preview"
  resource_id = each.value.id
  body = {
    properties = {
      useFreeLimit                = true
      freeLimitExhaustionBehavior = "AutoPause"
    }
  }
}
