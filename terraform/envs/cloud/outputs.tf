output "public_ip" {
  value = module.oci.public_ip
}

output "kubeconfig_hint" {
  value = module.oci.kubeconfig_hint
}

output "sql_server" {
  value = module.azure_sql.server_fqdn
}

output "demo_password" {
  description = "Password for the seeded demo users (operator1, punter1, ...)."
  value       = random_password.client["demo"].result
  sensitive   = true
}
