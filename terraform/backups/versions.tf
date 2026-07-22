terraform {
  required_version = ">= 1.5"
  required_providers {
    # Hetzner's recommended provider for Object Storage buckets (the hcloud provider has no
    # object-storage resource, and it's S3-compatible). See Hetzner docs "Creating a Bucket via
    # MinIO Terraform Provider".
    minio = {
      source  = "aminueza/minio"
      version = "~> 3.33"
    }
  }
}
