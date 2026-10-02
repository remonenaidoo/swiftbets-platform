provider "oci" {
  region = var.oci_region
}

provider "azurerm" {
  features {}
}

provider "kubernetes" {
  config_path = var.kubeconfig_path != "" ? var.kubeconfig_path : null
}

provider "helm" {
  kubernetes = {
    config_path = var.kubeconfig_path != "" ? var.kubeconfig_path : null
  }
}

locals {
  install  = var.kubeconfig_path != ""
  services = ["placement", "wallet", "settlement", "payout", "identity", "compliance", "payments", "casino"]
}

module "oci" {
  source              = "../../modules/oci"
  compartment_ocid    = var.compartment_ocid
  availability_domain = var.availability_domain
  ssh_public_key      = var.ssh_public_key
  admin_cidr          = var.admin_cidr
  shape               = var.shape
  arch                = var.arch
}

module "azure_sql" {
  source     = "../../modules/azure-sql"
  location   = var.azure_location
  allowed_ip = module.oci.public_ip
}

resource "random_password" "db" {
  for_each = toset(concat(local.services, ["steward", "history", "notifications", "config", "catalog", "casino-catalog", "risk", "postgres"]))
  length   = 32
  special  = false
}

resource "random_password" "client" {
  for_each = toset(["payout", "steward", "demo", "payments", "payments-simulator", "payments-webhook", "placement", "cashout", "history", "casino", "casino-sim-seamless", "casino-sim-transfer"])
  length   = 32
  special  = false
}

# HMAC key for cashout quote tokens: 32 random bytes, base64.
resource "random_id" "cashout_signing" {
  byte_length = 32
}

# The identity service's RS256 signing key: stable across restarts and shared by every replica.
resource "tls_private_key" "identity" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "kubernetes_namespace_v1" "swiftbets" {
  count = local.install ? 1 : 0
  metadata {
    name = "swiftbets"
  }
}

# The secret the chart reads instead of its local demo secret: Azure SQL over TLS, in-cluster Postgres.
resource "kubernetes_secret_v1" "swiftbets" {
  count = local.install ? 1 : 0
  metadata {
    name      = "swiftbets-secrets"
    namespace = kubernetes_namespace_v1.swiftbets[0].metadata[0].name
  }
  data = merge(
    {
      "demo-password"              = random_password.client["demo"].result
      "sqlserver-sa-password"      = module.azure_sql.admin_password
      "postgres-password"          = random_password.db["postgres"].result
      "payout-client-secret"       = random_password.client["payout"].result
      "steward-client-secret"      = random_password.client["steward"].result
      "payments-client-secret"     = random_password.client["payments"].result
      "placement-client-secret"    = random_password.client["placement"].result
      "cashout-client-secret"      = random_password.client["cashout"].result
      "casino-client-secret"       = random_password.client["casino"].result
      "casino-sim-seamless-secret" = random_password.client["casino-sim-seamless"].result
      "casino-sim-transfer-secret" = random_password.client["casino-sim-transfer"].result
      "history-client-secret"      = random_password.client["history"].result
      "cashout-signing-key"        = random_id.cashout_signing.b64_std
      "payments-simulator-api-key" = random_password.client["payments-simulator"].result
      "payments-webhook-secret"    = random_password.client["payments-webhook"].result
      "steward-db-password"        = random_password.db["steward"].result
      "history-db-password"        = random_password.db["history"].result
      "notifications-db-password"  = random_password.db["notifications"].result
      "config-db-password"         = random_password.db["config"].result
      "catalog-db-password"        = random_password.db["catalog"].result
      "casino-catalog-db-password" = random_password.db["casino-catalog"].result
      "risk-db-password"           = random_password.db["risk"].result
      "sb-steward"                 = "Host=postgres;Database=sb_steward;Username=steward_app;Password=${random_password.db["steward"].result}"
      "sb-history"                 = "Host=postgres;Database=sb_history;Username=history_app;Password=${random_password.db["history"].result}"
      "sb-notifications"           = "Host=postgres;Database=sb_notifications;Username=notifications_app;Password=${random_password.db["notifications"].result}"
      "sb-config"                  = "Host=postgres;Database=sb_config;Username=config_app;Password=${random_password.db["config"].result}"
      "sb-catalog"                 = "Host=postgres;Database=sb_catalog;Username=catalog_app;Password=${random_password.db["catalog"].result}"
      "sb-casino-catalog"          = "Host=postgres;Database=sb_casino;Username=casino_catalog_app;Password=${random_password.db["casino-catalog"].result}"
      "sb-risk"                    = "Host=postgres;Database=sb_risk;Username=risk_app;Password=${random_password.db["risk"].result}"
      "anthropic-api-key"          = var.anthropic_api_key
      "identity-signing-key"       = tls_private_key.identity.private_key_pem
    },
    { for s in local.services : "${s}-db-password" => random_password.db[s].result },
    { for s in local.services : "sb-${s}" => "Server=tcp:${module.azure_sql.server_fqdn},1433;Database=Sb${title(s)};User Id=${s}_app;Password=${random_password.db[s].result};Encrypt=True;TrustServerCertificate=False" },
    { for s in local.services : "sb-${s}-migrate" => "Server=tcp:${module.azure_sql.server_fqdn},1433;Database=Sb${title(s)};User Id=${module.azure_sql.admin_login};Password=${module.azure_sql.admin_password};Encrypt=True;TrustServerCertificate=False" },
  )
}

resource "helm_release" "swiftbets" {
  count             = local.install ? 1 : 0
  name              = "swiftbets"
  namespace         = kubernetes_namespace_v1.swiftbets[0].metadata[0].name
  chart             = "${path.module}/../../../charts/swiftbets"
  dependency_update = true
  values = concat([
    file("${path.module}/../../../charts/swiftbets/values-prod.yaml"),
    yamlencode({
      global  = { imageTag = var.image_tag }
      ingress = { host = var.ingress_host }
      infra = {
        sqlserver = { external = { host = module.azure_sql.server_fqdn } }
      }
    }),
    ], var.anthropic_api_key == "" ? [] : [yamlencode({
      steward = {
        env       = { Steward__ModelProvider__Provider = "anthropic" }
        secretEnv = { ANTHROPIC_API_KEY = { key = "anthropic-api-key" } }
      }
  })])
  timeout = 900
  wait    = true

  depends_on = [kubernetes_secret_v1.swiftbets]
}
