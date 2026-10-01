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
  services = ["placement", "wallet", "settlement", "payout"]
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
  for_each = toset(concat(local.services, ["steward", "history", "postgres"]))
  length   = 32
  special  = false
}

resource "random_password" "client" {
  for_each = toset(["payout", "steward", "demo"])
  length   = 32
  special  = false
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
      "demo-password"         = random_password.client["demo"].result
      "sqlserver-sa-password" = module.azure_sql.admin_password
      "postgres-password"     = random_password.db["postgres"].result
      "payout-client-secret"  = random_password.client["payout"].result
      "steward-client-secret" = random_password.client["steward"].result
      "steward-db-password"   = random_password.db["steward"].result
      "history-db-password"   = random_password.db["history"].result
      "sb-steward"            = "Host=postgres;Database=sb_steward;Username=steward_app;Password=${random_password.db["steward"].result}"
      "sb-history"            = "Host=postgres;Database=sb_history;Username=history_app;Password=${random_password.db["history"].result}"
      "anthropic-api-key"     = var.anthropic_api_key
      "identity-signing-key"  = tls_private_key.identity.private_key_pem
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
