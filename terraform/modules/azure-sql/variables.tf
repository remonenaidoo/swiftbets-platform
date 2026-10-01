variable "name" {
  description = "Prefix for resource names."
  type        = string
  default     = "swiftbets"
}

variable "location" {
  description = "Azure region, e.g. southafricanorth."
  type        = string
  default     = "southafricanorth"
}

variable "admin_login" {
  description = "Server administrator login; used only by migrators and the login-creation job."
  type        = string
  default     = "swiftbets_admin"
}

variable "allowed_ip" {
  description = "The single public IP allowed through the server firewall (the OCI k3s node)."
  type        = string
}

variable "databases" {
  description = "Betstore databases, one per owning service."
  type        = list(string)
  default     = ["SbPlacement", "SbWallet", "SbSettlement", "SbPayout", "SbIdentity", "SbCompliance"]
}
