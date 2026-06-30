# Hetzner Object Storage bucket for DB backups (S3-compatible), via the MinIO provider.
# Credentials (access/secret) come from the Hetzner Console (Object Storage -> Manage
# credentials) — there is no Terraform resource for them — and are passed via tfvars.
resource "minio_s3_bucket" "backups" {
  bucket         = var.backup_bucket
  acl            = "private" # backups must never be world-readable
  object_locking = false
}

# Databasus's view of that bucket (the backup destination).
resource "databasus_storage_s3" "hetzner" {
  name                        = "hetzner-${var.hetzner_s3_region}"
  workspace_id                = databasus_workspace.main.id
  s3_bucket                   = minio_s3_bucket.backups.bucket
  s3_endpoint                 = var.hetzner_s3_endpoint
  s3_region                   = var.hetzner_s3_region
  s3_access_key               = var.hetzner_s3_access_key
  s3_secret_key               = var.hetzner_s3_secret_key
  s3_prefix                   = "db/" # immutable after creation
  s3_use_virtual_hosted_style = true  # Hetzner supports it; flip to false if you hit COS errors
  skip_tls_verify             = false
  # Set explicitly — the provider returns "" / false for these, which trips Terraform's
  # "inconsistent result after apply" check if left unset (null).
  s3_storage_class = ""
  is_system        = false
}
