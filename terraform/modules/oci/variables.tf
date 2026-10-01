variable "compartment_ocid" {
  description = "Compartment for every resource."
  type        = string
}

variable "availability_domain" {
  description = "Availability domain name, e.g. Uocm:AF-JOHANNESBURG-1-AD-1."
  type        = string
}

variable "name" {
  description = "Prefix for resource names."
  type        = string
  default     = "swiftbets"
}

variable "shape" {
  description = "Instance shape. VM.Standard.A1.Flex is the Always Free Ampere (arm64) shape."
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "ocpus" {
  description = "OCPUs for a flex shape (Always Free allows up to 4 across A1 instances)."
  type        = number
  default     = 4
}

variable "memory_gb" {
  description = "Memory for a flex shape (Always Free allows up to 24 GB across A1 instances)."
  type        = number
  default     = 24
}

variable "arch" {
  description = "Image architecture: aarch64 for A1, x86_64 for AMD/Intel shapes."
  type        = string
  default     = "aarch64"
  validation {
    condition     = contains(["aarch64", "x86_64"], var.arch)
    error_message = "arch must be aarch64 or x86_64."
  }
}

variable "ssh_public_key" {
  description = "Public key authorised for the ubuntu user."
  type        = string
}

variable "admin_cidr" {
  description = "CIDR allowed to reach SSH and the Kubernetes API (your own IP/32)."
  type        = string
}

variable "k3s_version" {
  description = "k3s release to install."
  type        = string
  default     = "v1.34.1+k3s1"
}
