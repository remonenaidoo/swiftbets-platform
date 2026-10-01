terraform {
  required_version = ">= 1.9"

  required_providers {
    oci        = { source = "oracle/oci", version = "~> 7.0" }
    azurerm    = { source = "hashicorp/azurerm", version = "~> 4.0" }
    azapi      = { source = "azure/azapi", version = "~> 2.0" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
    tls        = { source = "hashicorp/tls", version = "~> 4.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
  }

  # State lives in OCI Object Storage through its S3-compatible API. Supply the bucket, region and endpoint at
  # init time: terraform init -backend-config=backend.hcl (see backend.hcl.example and docs/DEPLOY.md).
  backend "s3" {
    key                         = "swiftbets/prod.tfstate"
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
