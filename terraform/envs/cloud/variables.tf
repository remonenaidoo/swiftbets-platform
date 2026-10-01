variable "oci_region" {
  type    = string
  default = "af-johannesburg-1"
}

variable "compartment_ocid" {
  type = string
}

variable "availability_domain" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "admin_cidr" {
  description = "Your IP/32, for SSH and the Kubernetes API."
  type        = string
}

variable "shape" {
  type    = string
  default = "VM.Standard.A1.Flex"
}

variable "arch" {
  type    = string
  default = "aarch64"
}

variable "azure_location" {
  type    = string
  default = "southafricanorth"
}

variable "kubeconfig_path" {
  description = "Empty on the first apply (infrastructure only). After k3s is up, fetch its kubeconfig (see the kubeconfig_hint output) and apply again with this set to install the chart."
  type        = string
  default     = ""
}

variable "image_tag" {
  description = "Image tag every service runs (a release tag, or main)."
  type        = string
  default     = "main"
}

variable "ingress_host" {
  description = "Host name the ingress answers on; empty answers on any host."
  type        = string
  default     = ""
}

variable "anthropic_api_key" {
  description = "Optional. Without it Steward runs on its scripted replay model."
  type        = string
  default     = ""
  sensitive   = true
}
