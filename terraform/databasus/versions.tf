terraform {
  required_version = ">= 1.5"
  required_providers {
    # Unofficial Databasus provider — PIN it to match the running Databasus image version.
    # Support map (from the provider docs): v0.8.1+ <-> Databasus v3.42.0. Bump deliberately.
    databasus = {
      source  = "pkerspe/databasus"
      version = "~> 0.8.1"
    }
    # Hetzner's recommended provider for Object Storage buckets (the hcloud provider has no
    # object-storage resource, and it's S3-compatible). See Hetzner docs "Creating a Bucket via
    # MinIO Terraform Provider".
    minio = {
      source  = "aminueza/minio"
      version = "~> 3.33"
    }
  }
}
